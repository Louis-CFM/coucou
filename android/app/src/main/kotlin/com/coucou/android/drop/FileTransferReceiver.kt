package com.coucou.android.drop

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Base64
import com.coucou.android.link.DesktopLink
import com.coucou.android.link.ServerMsg
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap

/**
 * Handles incoming Vayli Drop file transfers from the desktop computer over the authenticated Coucou link.
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

        // 2. Prepare staging file
        try {
            val tempFile = File(context.cacheDir, "vayli_drop_${offer.transferId}.tmp")
            if (tempFile.exists()) tempFile.delete()

            val fos = FileOutputStream(tempFile)
            val digest = MessageDigest.getInstance("SHA-256")

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

            // 3. Accept transfer
            currentLink.dropAccept(offer.transferId)
            notifications.showProgress(offer.transferId, offer.name, 0, offer.size)
            onTransferProgress?.invoke(record, 0f)
        } catch (e: Exception) {
            currentLink.dropReject(offer.transferId, "io_error: ${e.message}")
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
                tempFile.inputStream().use { inp -> inp.copyTo(out) }
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
                destFile.outputStream().use { out -> inp.copyTo(out) }
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
