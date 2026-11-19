package com.coucou.android.drop

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Base64
import android.util.Log
import com.coucou.android.link.DesktopLink
import com.coucou.android.link.ServerMsg
import java.io.BufferedOutputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * CouDrop High-Performance Transfer Engine (FileTransferSender).
 * Supports CouDrop Protocol V2 (LocalSend-style raw binary streaming over dedicated local HTTP channel)
 * with single-pass on-the-fly hashing (zero pre-read latency) and fallback to V1 chunked TLS framing.
 */
class FileTransferSender(
    private val context: Context,
    private val link: () -> DesktopLink?,
    private val notifications: TransferNotificationManager = TransferNotificationManager(context),
) {
    private val executor = Executors.newSingleThreadExecutor()
    private val activeTransfers = ConcurrentHashMap<String, Boolean>()
    private val pendingAccepts = ConcurrentHashMap<String, (Boolean, String, ServerMsg.DropAccept?) -> Unit>()
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

                    val actualSize = meta.size

                    // Coordinate dropOffer / dropAccept (No pre-reading file! Zero latency start)
                    val acceptLatch = CountDownLatch(1)
                    var isAccepted = true
                    var rejectReason = ""
                    var acceptMsg: ServerMsg.DropAccept? = null

                    pendingAccepts[transferId] = { accepted, reason, msg ->
                        isAccepted = accepted
                        rejectReason = reason
                        acceptMsg = msg
                        acceptLatch.countDown()
                    }

                    // Send drop offer advertising protocolVersion = 2
                    currentLink.dropOffer(
                        transferId = transferId,
                        name = meta.name,
                        size = actualSize,
                        sha256 = "", // Single-pass on the fly; verified on completion
                        mimeType = meta.mimeType,
                        protocolVersion = 2,
                    )

                    // Wait up to 5s for desktop to accept
                    val responded = acceptLatch.await(5000, TimeUnit.MILLISECONDS)
                    pendingAccepts.remove(transferId)

                    if (responded && !isAccepted) {
                        throw IllegalStateException("Computer rejected transfer: $rejectReason")
                    }

                    var finalSha256 = ""

                    // Check if peer agreed on Protocol V2 (dedicated high-speed binary stream)
                    val useV2 = acceptMsg != null && acceptMsg!!.protocolVersion >= 2 && acceptMsg!!.dataPort > 0

                    if (useV2) {
                        // ── COUDROP PROTOCOL V2: DIRECT HIGH-SPEED BINARY STREAM ──────
                        val port = acceptMsg!!.dataPort
                        val token = acceptMsg!!.token
                        val offset = acceptMsg!!.offset.coerceAtLeast(0L)
                        val host = currentLink.desktopHost.ifBlank { "127.0.0.1" }
                        val url = URL("http://$host:$port/coudrop/v2/upload/$transferId")

                        val conn = (url.openConnection() as HttpURLConnection).apply {
                            requestMethod = "POST"
                            doOutput = true
                            connectTimeout = 10000
                            readTimeout = 60000
                            setRequestProperty("X-Coudrop-Token", token)
                            if (offset > 0L) {
                                setRequestProperty("X-Coudrop-Offset", offset.toString())
                            }
                            setRequestProperty("Connection", "close")
                            val bytesToSend = if (actualSize > offset) actualSize - offset else 0L
                            if (bytesToSend > 0) {
                                setFixedLengthStreamingMode(bytesToSend)
                            } else {
                                setChunkedStreamingMode(512 * 1024)
                            }
                        }

                        val digest = MessageDigest.getInstance("SHA-256")
                        val buffer = ByteArray(512 * 1024)
                        var bytesTransferred = offset
                        var lastNotifyTime = System.currentTimeMillis()
                        var lastNotifyBytes = bytesTransferred

                        if (offset > 0L) {
                            var skipped = 0L
                            while (skipped < offset) {
                                val s = stream.skip(offset - skipped)
                                if (s <= 0L) break
                                skipped += s
                            }
                        }

                        val outStream = BufferedOutputStream(conn.outputStream, 512 * 1024)
                        try {
                            while (activeTransfers[transferId] == true) {
                                val read = stream.read(buffer)
                                if (read == -1) break
                                outStream.write(buffer, 0, read)
                                digest.update(buffer, 0, read)
                                bytesTransferred += read

                                val now = System.currentTimeMillis()
                                val elapsed = now - lastNotifyTime
                                if (elapsed >= 250) {
                                    val speedMBps = if (elapsed > 0) ((bytesTransferred - lastNotifyBytes) / (1024.0 * 1024.0)) / (elapsed / 1000.0) else 0.0
                                    val prog = if (actualSize > 0) (bytesTransferred.toFloat() / actualSize).coerceIn(0f, 0.99f) else 0f
                                    notifications.showProgress(transferId, meta.name, bytesTransferred, actualSize)
                                    onProgress?.invoke(record, prog, speedMBps)
                                    lastNotifyTime = now
                                    lastNotifyBytes = bytesTransferred
                                }
                            }
                            outStream.flush()
                        } finally {
                            runCatching { outStream.close() }
                        }

                        val respCode = conn.responseCode
                        if (respCode !in 200..299) {
                            throw IllegalStateException("Computer returned HTTP $respCode for binary upload")
                        }

                        finalSha256 = digest.digest().joinToString("") { "%02x".format(it) }
                    } else {
                        // ── FALLBACK: V1 BASE64 TLS FRAMING ────────────────────────────
                        val digest = MessageDigest.getInstance("SHA-256")
                        val buffer = ByteArray(32 * 1024)
                        var bytesRead = 0
                        var bytesTransferred = 0L
                        var chunkIndex = 0
                        val totalChunks = if (actualSize > 0) Math.ceil(actualSize.toDouble() / buffer.size).toInt().coerceAtLeast(1) else 1
                        val startTime = System.currentTimeMillis()

                        while (activeTransfers[transferId] == true && stream.read(buffer).also { bytesRead = it } != -1) {
                            digest.update(buffer, 0, bytesRead)
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
                            val prog = if (actualSize > 0) (bytesTransferred.toFloat() / actualSize).coerceIn(0f, 0.99f) else 0f

                            notifications.showProgress(transferId, meta.name, bytesTransferred, actualSize)
                            onProgress?.invoke(record, prog, speedMBps)
                        }
                        finalSha256 = digest.digest().joinToString("") { "%02x".format(it) }
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

                        currentLink.dropDone(transferId, finalSha256)

                        val doneResponded = doneLatch.await(8000, TimeUnit.MILLISECONDS)
                        pendingDone.remove(transferId)

                        if (doneResponded && !isDoneConfirmed) {
                            throw IllegalStateException("Computer reported transfer failure: $doneError")
                        }

                        notifications.showComplete(transferId, meta.name, actualSize, uri, meta.mimeType)
                        onComplete?.invoke(record.copy(status = TransferStatus.COMPLETED, sha256 = finalSha256))
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

    fun onAccept(accept: ServerMsg.DropAccept) {
        pendingAccepts[accept.transferId]?.invoke(true, "", accept)
    }

    fun onAccept(transferId: String) {
        pendingAccepts[transferId]?.invoke(true, "", null)
    }

    fun onReject(transferId: String, reason: String) {
        pendingAccepts[transferId]?.invoke(false, reason, null)
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
