package com.coucou.android.drop

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Base64
import android.util.Log
import com.coucou.android.link.DesktopLink
import com.coucou.android.link.ServerMsg
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * CouDrop High-Performance Transfer Engine (FileTransferReceiver).
 * Handles incoming file transfers from the desktop computer.
 * Supports CouDrop Protocol V2 (LocalSend-style raw binary streaming over dedicated local HTTP channel)
 * with single-pass on-the-fly hashing and fallback to V1 chunked TLS framing.
 */
class FileTransferReceiver(
    private val context: Context,
    private val link: () -> DesktopLink?,
    private val notifications: TransferNotificationManager = TransferNotificationManager(context),
    private val historyStore: CoudropHistoryStore = CoudropHistoryStore(context),
    private val onTransferProgress: ((record: CoudropRecord, progress: Float) -> Unit)? = null,
    private val onTransferComplete: ((record: CoudropRecord) -> Unit)? = null,
    private val onTransferFailed: ((transferId: String, reason: String) -> Unit)? = null,
) {
    private val executor = Executors.newCachedThreadPool()
    private val cancelledTransfers = ConcurrentHashMap<String, Boolean>()

    private class ActiveTransfer(
        val transferId: String,
        val name: String,
        val size: Long,
        val expectedSha256: String,
        val mimeType: String,
        val tempFile: File,
        val outputStream: FileOutputStream,
        val digest: MessageDigest,
        val record: CoudropRecord,
        var bytesReceived: Long = 0L,
    )

    private val activeTransfers = ConcurrentHashMap<String, ActiveTransfer>()

    fun onOffer(offer: ServerMsg.DropOffer) {
        val currentLink = link() ?: return

        // 1. Validate free space
        val freeBytes = context.cacheDir.usableSpace
        if (offer.size > 0 && freeBytes < offer.size + 10_000_000L) {
            currentLink.dropReject(offer.transferId, "insufficient_storage")
            return
        }

        cancelledTransfers.remove(offer.transferId)

        val record = CoudropRecord(
            id = offer.transferId,
            name = offer.name,
            size = offer.size,
            direction = TransferDirection.INCOMING,
            status = TransferStatus.IN_PROGRESS,
            timestampMs = System.currentTimeMillis(),
            mimeType = offer.mimeType,
            sha256 = offer.sha256,
        )

        // Check if desktop offered Protocol V2 (Dedicated High-Speed Binary Stream)
        if (offer.protocolVersion >= 2 && offer.dataPort > 0) {
            // ── COUDROP PROTOCOL V2: DIRECT HIGH-SPEED BINARY DOWNLOAD ──────
            try {
                val tempFile = File(context.cacheDir, "vayli_drop_${offer.transferId}.tmp")
                if (tempFile.exists()) tempFile.delete()

                // Accept transfer with Protocol V2
                currentLink.dropAccept(offer.transferId, protocolVersion = 2)
                notifications.showProgress(offer.transferId, offer.name, 0, offer.size)
                onTransferProgress?.invoke(record, 0f)

                executor.execute {
                    downloadV2(offer, tempFile, record)
                }
            } catch (e: Exception) {
                Log.e("CoudropReceiver", "Failed to start V2 transfer for ${offer.name}", e)
                currentLink.dropReject(offer.transferId, "init_error: ${e.message}")
            }
            return
        }

        // ── FALLBACK: V1 CHUNKED BASE64 TLS FRAMING ────────────────────────
        try {
            val tempFile = File(context.cacheDir, "vayli_drop_${offer.transferId}.tmp")
            if (tempFile.exists()) tempFile.delete()

            val fos = FileOutputStream(tempFile)
            val digest = MessageDigest.getInstance("SHA-256")

            val transfer = ActiveTransfer(
                transferId = offer.transferId,
                name = offer.name,
                size = offer.size,
                expectedSha256 = offer.sha256,
                mimeType = offer.mimeType,
                tempFile = tempFile,
                outputStream = fos,
                digest = digest,
                record = record,
            )
            activeTransfers[offer.transferId] = transfer

            // Accept transfer
            currentLink.dropAccept(offer.transferId)
            notifications.showProgress(offer.transferId, offer.name, 0, offer.size)
            onTransferProgress?.invoke(record, 0f)
        } catch (e: Exception) {
            currentLink.dropReject(offer.transferId, "io_error: ${e.message}")
        }
    }

    private fun downloadV2(offer: ServerMsg.DropOffer, tempFile: File, record: CoudropRecord) {
        val currentLink = link() ?: return
        val host = currentLink.desktopHost.ifBlank { "127.0.0.1" }
        val url = URL("http://$host:${offer.dataPort}/coudrop/v2/download/${offer.transferId}")

        var conn: HttpURLConnection? = null
        var inStream: BufferedInputStream? = null
        var outStream: BufferedOutputStream? = null

        try {
            conn = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = 10000
                readTimeout = 60000
                setRequestProperty("X-Coudrop-Token", offer.token)
                setRequestProperty("Connection", "close")
            }

            val respCode = conn.responseCode
            if (respCode !in 200..299) {
                throw IllegalStateException("Computer returned HTTP $respCode for binary download")
            }

            inStream = BufferedInputStream(conn.inputStream, 512 * 1024)
            outStream = BufferedOutputStream(FileOutputStream(tempFile), 512 * 1024)

            val digest = MessageDigest.getInstance("SHA-256")
            val buffer = ByteArray(512 * 1024)
            var bytesRead: Int
            var bytesReceived = 0L
            var lastNotifyTime = System.currentTimeMillis()

            while (cancelledTransfers[offer.transferId] != true) {
                bytesRead = inStream.read(buffer)
                if (bytesRead == -1) break
                outStream.write(buffer, 0, bytesRead)
                digest.update(buffer, 0, bytesRead)
                bytesReceived += bytesRead

                val now = System.currentTimeMillis()
                val elapsed = now - lastNotifyTime
                if (elapsed >= 250) {
                    val prog = if (offer.size > 0) (bytesReceived.toFloat() / offer.size).coerceIn(0f, 0.99f) else 0f
                    notifications.showProgress(offer.transferId, offer.name, bytesReceived, offer.size)
                    onTransferProgress?.invoke(record, prog)
                    lastNotifyTime = now
                }
            }

            outStream.flush()
            outStream.close()
            outStream = null

            if (cancelledTransfers[offer.transferId] == true) {
                tempFile.delete()
                notifications.dismiss(offer.transferId)
                return
            }

            val computedSha256 = digest.digest().joinToString("") { "%02x".format(it) }

            // Verify checksum if expected hash was provided
            if (offer.sha256.isNotBlank() && !computedSha256.equals(offer.sha256, ignoreCase = true)) {
                tempFile.delete()
                notifications.dismiss(offer.transferId)
                onTransferFailed?.invoke(offer.transferId, "checksum_mismatch")
                currentLink.dropReject(offer.transferId, "checksum_mismatch")
                return
            }

            // Save to Downloads folder
            val savedUri = saveToDownloads(tempFile, offer.name, offer.mimeType)
            tempFile.delete()

            val completedRecord = record.copy(
                status = TransferStatus.COMPLETED,
                size = bytesReceived,
                uriString = savedUri?.toString(),
                sha256 = computedSha256,
            )
            historyStore.addRecord(completedRecord)
            onTransferComplete?.invoke(completedRecord)

            notifications.showComplete(offer.transferId, offer.name, bytesReceived, savedUri, offer.mimeType)
            currentLink.dropDone(offer.transferId, computedSha256)
        } catch (e: Exception) {
            Log.e("CoudropReceiver", "V2 download failed for ${offer.name}", e)
            tempFile.delete()
            notifications.dismiss(offer.transferId)
            onTransferFailed?.invoke(offer.transferId, "download_error: ${e.message}")
            currentLink.dropReject(offer.transferId, "download_error: ${e.message}")
        } finally {
            runCatching { inStream?.close() }
            runCatching { outStream?.close() }
            conn?.disconnect()
            cancelledTransfers.remove(offer.transferId)
        }
    }

    fun onChunk(chunk: ServerMsg.DropChunk) {
        val transfer = activeTransfers[chunk.transferId] ?: return
        val currentLink = link() ?: return

        try {
            val bytes = Base64.decode(chunk.data, Base64.DEFAULT)
            transfer.outputStream.write(bytes)
            transfer.digest.update(bytes)
            transfer.bytesReceived += bytes.size

            val prog = if (transfer.size > 0) (transfer.bytesReceived.toFloat() / transfer.size).coerceIn(0f, 1f) else 0f
            onTransferProgress?.invoke(transfer.record, prog)

            // Report progress every few chunks
            currentLink.dropProgress(chunk.transferId, transfer.bytesReceived, transfer.size)
            notifications.showProgress(chunk.transferId, transfer.name, transfer.bytesReceived, transfer.size)

            // Final chunk check
            if (chunk.index == chunk.total - 1 || (transfer.size > 0 && transfer.bytesReceived >= transfer.size)) {
                completeTransfer(transfer)
            }
        } catch (e: Exception) {
            cleanup(chunk.transferId, "write_error: ${e.message}")
            currentLink.dropReject(chunk.transferId, "write_error: ${e.message}")
        }
    }

    fun onCancel(cancel: ServerMsg.DropCancel) {
        cancelledTransfers[cancel.transferId] = true
        cleanup(cancel.transferId, cancel.reason)
    }

    private fun completeTransfer(transfer: ActiveTransfer) {
        val currentLink = link()
        activeTransfers.remove(transfer.transferId)

        try {
            transfer.outputStream.flush()
            transfer.outputStream.close()

            // Verify checksum
            val hashBytes = transfer.digest.digest()
            val computedSha256 = hashBytes.joinToString("") { "%02x".format(it) }

            if (transfer.expectedSha256.isNotBlank() && !computedSha256.equals(transfer.expectedSha256, ignoreCase = true)) {
                transfer.tempFile.delete()
                notifications.dismiss(transfer.transferId)
                onTransferFailed?.invoke(transfer.transferId, "checksum_mismatch")
                currentLink?.dropReject(transfer.transferId, "checksum_mismatch")
                return
            }

            // Save to Downloads folder
            val savedUri = saveToDownloads(transfer.tempFile, transfer.name, transfer.mimeType)
            transfer.tempFile.delete()

            val completedRecord = transfer.record.copy(
                status = TransferStatus.COMPLETED,
                size = transfer.bytesReceived,
                uriString = savedUri?.toString(),
                sha256 = computedSha256,
            )
            historyStore.addRecord(completedRecord)
            onTransferComplete?.invoke(completedRecord)

            notifications.showComplete(transfer.transferId, transfer.name, transfer.bytesReceived, savedUri, transfer.mimeType)
            currentLink?.dropDone(transfer.transferId, computedSha256)
        } catch (e: Exception) {
            transfer.tempFile.delete()
            notifications.dismiss(transfer.transferId)
            onTransferFailed?.invoke(transfer.transferId, "save_error: ${e.message}")
            currentLink?.dropReject(transfer.transferId, "save_error: ${e.message}")
        }
    }

    private fun saveToDownloads(tempFile: File, fileName: String, mimeType: String): Uri? {
        val resolver = context.contentResolver
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val contentValues = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }

            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, contentValues) ?: return null
            resolver.openOutputStream(uri)?.use { out ->
                tempFile.inputStream().use { inp -> inp.copyTo(out, bufferSize = 512 * 1024) }
            }
            contentValues.clear()
            contentValues.put(MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(uri, contentValues, null, null)
            return uri
        } else {
            @Suppress("DEPRECATION")
            val downloadsDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            val destFile = resolveCollision(downloadsDir, fileName)
            tempFile.inputStream().use { inp ->
                destFile.outputStream().use { out -> inp.copyTo(out, bufferSize = 512 * 1024) }
            }
            return Uri.fromFile(destFile)
        }
    }

    private fun resolveCollision(dir: File, baseName: String): File {
        val file = File(dir, baseName)
        if (!file.exists()) return file

        val nameNoExt = file.nameWithoutExtension
        val ext = if (file.extension.isNotEmpty()) ".${file.extension}" else ""
        for (i in 1..9999) {
            val candidate = File(dir, "$nameNoExt ($i)$ext")
            if (!candidate.exists()) return candidate
        }
        return File(dir, "${nameNoExt}_${System.currentTimeMillis()}$ext")
    }

    private fun cleanup(transferId: String, reason: String = "cancelled") {
        val transfer = activeTransfers.remove(transferId) ?: return
        runCatching { transfer.outputStream.close() }
        runCatching { transfer.tempFile.delete() }
        notifications.dismiss(transferId)
        onTransferFailed?.invoke(transferId, reason)
    }
}
