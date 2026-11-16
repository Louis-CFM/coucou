package com.coucou.android.drop

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Base64
import android.util.Log
import com.coucou.android.link.DesktopLink
import java.io.InputStream
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Streams files from Android (via ContentResolver URIs) to Desktop over authenticated TLS connection.
 */
class FileTransferSender(
    private val context: Context,
    private val link: () -> DesktopLink?,
    private val notifications: TransferNotificationManager = TransferNotificationManager(context),
) {
    private val executor = Executors.newSingleThreadExecutor()
    private val activeTransfers = ConcurrentHashMap<String, Boolean>()
    private val pendingAccepts = ConcurrentHashMap<String, (Boolean, String) -> Unit>()
    private val pendingDone = ConcurrentHashMap<String, (Boolean, String) -> Unit>()

    data class SendMetadata(
        val name: String,
        val size: Long,
        val mimeType: String,
    )

    fun resolveMetadata(uri: Uri): SendMetadata {
        var name = "file"
        var size = 0L
        val mimeType = context.contentResolver.getType(uri) ?: "application/octet-stream"

        runCatching {
            context.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val nameIdx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeIdx = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (cursor.moveToFirst()) {
                    if (nameIdx >= 0) name = cursor.getString(nameIdx) ?: "file"
                    if (sizeIdx >= 0) size = cursor.getLong(sizeIdx)
                }
            }
        }

        if (size <= 0L) {
            runCatching {
                context.contentResolver.openFileDescriptor(uri, "r")?.use { pfd ->
                    size = pfd.statSize
                }
            }
        }

        return SendMetadata(name = name, size = size, mimeType = mimeType)
    }

    fun sendUris(
        uris: List<Uri>,
        onProgress: ((record: CoudropRecord, progress: Float, speedMBps: Double) -> Unit)? = null,
        onComplete: ((record: CoudropRecord) -> Unit)? = null,
        onError: ((transferId: String, error: String) -> Unit)? = null,
    ) {
        val currentLink = link()
        if (currentLink == null) {
            onError?.invoke("", "No active connection to computer")
            return
        }

        executor.execute {
            for (uri in uris) {
                val meta = resolveMetadata(uri)
                val transferId = "drop_${UUID.randomUUID().toString().replace("-", "").take(12)}"
                activeTransfers[transferId] = true

                val record = CoudropRecord(
                    id = transferId,
                    name = meta.name,
                    size = meta.size,
                    direction = TransferDirection.OUTGOING,
                    status = TransferStatus.IN_PROGRESS,
                    timestampMs = System.currentTimeMillis(),
                    uriString = uri.toString(),
                    mimeType = meta.mimeType,
                )

                var stream: InputStream? = null
                try {
                    stream = context.contentResolver.openInputStream(uri)
                        ?: throw IllegalStateException("Cannot open input stream for $uri")

                    // First pass: compute SHA-256 and confirm total bytes
                    val digest = MessageDigest.getInstance("SHA-256")
                    val buffer = ByteArray(32 * 1024)
                    var bytesRead: Int
                    var totalRead = 0L

                    while (stream.read(buffer).also { bytesRead = it } != -1) {
                        digest.update(buffer, 0, bytesRead)
                        totalRead += bytesRead
                    }
                    val actualSize = if (meta.size > 0L) meta.size else totalRead
                    val sha256 = digest.digest().joinToString("") { "%02x".format(it) }
                    stream.close()

                    // Reopen for actual transmission
                    stream = context.contentResolver.openInputStream(uri)
                        ?: throw IllegalStateException("Cannot re-open stream for $uri")

                    // Coordinate dropOffer / dropAccept
                    val acceptLatch = CountDownLatch(1)
                    var isAccepted = true
                    var rejectReason = ""

                    pendingAccepts[transferId] = { accepted, reason ->
                        isAccepted = accepted
                        rejectReason = reason
                        acceptLatch.countDown()
                    }

                    // Send drop offer
                    currentLink.dropOffer(
                        transferId = transferId,
                        name = meta.name,
                        size = actualSize,
                        sha256 = sha256,
                        mimeType = meta.mimeType,
                    )

                    // Wait up to 5s for desktop to accept
                    val responded = acceptLatch.await(5000, TimeUnit.MILLISECONDS)
                    pendingAccepts.remove(transferId)

                    if (responded && !isAccepted) {
                        throw IllegalStateException("Computer rejected transfer: $rejectReason")
                    }

                    val startTime = System.currentTimeMillis()
                    var bytesTransferred = 0L
                    var chunkIndex = 0
                    val totalChunks = if (actualSize > 0) Math.ceil(actualSize.toDouble() / buffer.size).toInt().coerceAtLeast(1) else 1

                    while (activeTransfers[transferId] == true && stream.read(buffer).also { bytesRead = it } != -1) {
                        val base64Data = Base64.encodeToString(buffer, 0, bytesRead, Base64.NO_WRAP)
                        currentLink.dropChunk(
                            transferId = transferId,
                            index = chunkIndex,
                            total = totalChunks,
                            data = base64Data,
                        )

                        bytesTransferred += bytesRead
                        chunkIndex++

                        val elapsedSec = (System.currentTimeMillis() - startTime) / 1000.0
                        val speedMBps = if (elapsedSec > 0.05) (bytesTransferred / (1024.0 * 1024.0)) / elapsedSec else 0.0
                        val prog = if (actualSize > 0) (bytesTransferred.toFloat() / actualSize).coerceIn(0f, 1f) else 0f

                        notifications.showProgress(transferId, meta.name, bytesTransferred, actualSize)
                        onProgress?.invoke(record, prog, speedMBps)
                    }

                    if (activeTransfers[transferId] == true) {
                        // Wait for desktop dropDone acknowledgement
                        val doneLatch = CountDownLatch(1)
                        var isDoneConfirmed = true
                        var doneError = ""

                        pendingDone[transferId] = { confirmed, error ->
                            isDoneConfirmed = confirmed
                            doneError = error
                            doneLatch.countDown()
                        }

                        currentLink.dropDone(transferId, sha256)

                        val doneResponded = doneLatch.await(8000, TimeUnit.MILLISECONDS)
                        pendingDone.remove(transferId)

                        if (doneResponded && !isDoneConfirmed) {
                            throw IllegalStateException("Computer reported transfer failure: $doneError")
                        }

                        notifications.showComplete(transferId, meta.name, actualSize, uri, meta.mimeType)
                        onComplete?.invoke(record.copy(status = TransferStatus.COMPLETED, sha256 = sha256))
                    } else {
                        currentLink.dropCancel(transferId, "cancelled")
                    }
                } catch (e: Exception) {
                    Log.e("CoudropSender", "Transfer failed for $uri", e)
                    pendingAccepts.remove(transferId)
                    pendingDone.remove(transferId)
                    onError?.invoke(transferId, e.message ?: "Transfer failed")
                    currentLink.dropCancel(transferId, e.message ?: "error")
                } finally {
                    runCatching { stream?.close() }
                    activeTransfers.remove(transferId)
                }
            }
        }
    }

    fun onAccept(transferId: String) {
        pendingAccepts[transferId]?.invoke(true, "")
    }

    fun onReject(transferId: String, reason: String) {
        pendingAccepts[transferId]?.invoke(false, reason)
        pendingDone[transferId]?.invoke(false, reason)
        activeTransfers.remove(transferId)
    }

    fun onDone(transferId: String, sha256: String) {
        pendingDone[transferId]?.invoke(true, "")
    }

    fun cancel(transferId: String) {
        activeTransfers.remove(transferId)
        pendingAccepts.remove(transferId)
        pendingDone.remove(transferId)
        link()?.dropCancel(transferId, "user_cancelled")
    }
}
