package com.coucou.android.link

import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * The relay half of a pairing link (docs/RELAY_LINK.md section 2): `relay`, `room`, `key` and `access`, present together
 * or not at all. [key] is K and [access] is the relay's access key, both only ever kept encrypted by [SecureStore].
 */
data class RelayPairing(val url: String, val room: String, val key: String, val access: String) {
    /** Never prints a secret: a log line or a crash report that formats a pairing shows nothing of it. */
    override fun toString() = "RelayPairing(..)"

    fun relayUrl(): RelayUrl? = RelayUrl.parse(url)
    fun pairingKey(): RelayCrypto.PairingKey? = RelayCrypto.PairingKey.fromBase64Url(key)

    companion object {
        sealed class Parsed {
            /** None of the four fields: a LAN-only link. */
            object Absent : Parsed()
            /** Some but not all, or one that is malformed: the whole link is refused. */
            object Invalid : Parsed()
            class Ok(val relay: RelayPairing) : Parsed()
        }

        fun isRoom(s: String) = s.length == 22 && RelayCrypto.base64UrlDecode(s)?.size == 16
        fun isSecret(s: String) = s.length == 43 && RelayCrypto.base64UrlDecode(s)?.size == 32

        fun fromQuery(q: Map<String, String>): Parsed {
            val fields = listOf("relay", "room", "key", "access").map { q[it] }
            if (fields.all { it == null }) return Parsed.Absent
            val (url, room, key, access) = fields
            if (url == null || room == null || key == null || access == null) return Parsed.Invalid
            val parsed = RelayUrl.parse(url) ?: return Parsed.Invalid
            if (!isRoom(room) || !isSecret(key) || !isSecret(access)) return Parsed.Invalid
            return Parsed.Ok(RelayPairing(parsed.display, room, key, access))
        }
    }
}

/** Why the last attempt through the relay did not work, for the status line in Settings. */
enum class RelayIssue { NONE, ACCESS_REFUSED, ROOM_TAKEN, RATE_LIMITED, UNREACHABLE, COMPUTER_AWAY }

/**
 * Connects to the computer through the user's relay: the WebSocket upgrade with the access key and the join proof, then the
 * end-to-end handshake (`init`, `accept`), then an ordinary [Socket] whose lines are the v1 conversation, encrypted. The
 * [LinkClient] on top is unchanged: it neither knows nor cares that the bytes go through a relay.
 */
class RelayConnector(
    private val relay: RelayPairing,
    private val sockets: (RelayUrl, Int) -> Socket = WsClient.defaultSockets,
    /** How long to wait for the computer to answer `init` before giving up (the link retries with its backoff). */
    private val answerTimeoutMs: Int = 15_000,
    /** How often `init` is sent again while no answer has come (an answer can be missed if the computer joined just after). */
    private val resendMs: Int = 4_000,
) : Connector {
    @Volatile var issue: RelayIssue = RelayIssue.NONE
        private set

    override fun connect(timeoutMs: Int): Socket {
        val url = relay.relayUrl() ?: throw IOException("bad relay address")
        val key = relay.pairingKey() ?: throw IOException("bad pairing key")
        val ws = try {
            WsClient.open(
                url = url,
                path = "/v1/room/${relay.room}?role=phone",
                headers = listOf("Authorization" to "Bearer ${relay.access}"),
                protocols = listOf(SUBPROTOCOL, "coucou.join.${RelayCrypto.joinProof(key)}"),
                connectTimeoutMs = timeoutMs,
                maxMessage = RelayCrypto.MAX_FRAME + 1024,
                sockets = sockets,
            )
        } catch (e: WsHandshakeException) {
            issue = when (e.status) {
                401, 403 -> RelayIssue.ACCESS_REFUSED
                429 -> RelayIssue.RATE_LIMITED
                else -> RelayIssue.UNREACHABLE
            }
            throw e
        } catch (e: IOException) {
            issue = RelayIssue.UNREACHABLE
            throw e
        }
        try {
            val session = handshake(ws, key)
            issue = RelayIssue.NONE
            return RelayStreamSocket(ws, session)
        } catch (e: Throwable) {
            ws.close()
            throw e
        }
    }

    private fun handshake(ws: WsConnection, key: RelayCrypto.PairingKey): RelayCrypto.Session {
        val deadline = System.nanoTime() + answerTimeoutMs * 1_000_000L
        var nonce = RelayCrypto.freshNonce()
        sendInit(ws, key, nonce)
        while (true) {
            val left = ((deadline - System.nanoTime()) / 1_000_000L).toInt()
            if (left <= 0) {
                issue = RelayIssue.COMPUTER_AWAY
                throw IOException("the computer did not answer")
            }
            ws.setReadTimeout(minOf(left, resendMs))
            val message = try {
                ws.receive()
            } catch (_: SocketTimeoutException) {
                nonce = RelayCrypto.freshNonce() // still nobody: ask again with a fresh nonce
                sendInit(ws, key, nonce)
                continue
            }
            when (message) {
                is WsMessage.Binary -> {
                    val frame = message.data
                    if (frame.size > 1 && frame[1].toInt() == RelayCrypto.T_ACCEPT) {
                        try {
                            return RelayCrypto.finishHandshake(key, relay.room, nonce, frame)
                        } catch (_: RelayCrypto.ChannelException) {
                            // An answer to an older init, or not from a holder of K: wait for the right one.
                        }
                    }
                }
                is WsMessage.Text -> if (RelayHints.parse(message.text) == RelayHints.Hint.ONLINE) {
                    nonce = RelayCrypto.freshNonce()
                    sendInit(ws, key, nonce)
                }
                is WsMessage.Closed -> {
                    issue = issueOf(message.reason)
                    throw IOException("the relay closed the connection")
                }
            }
        }
    }

    /**
     * Sends `init`. If the relay has already closed the connection, the write fails before the close frame is read, so the
     * reason is fetched (briefly) to tell "the room is taken" from "the network dropped".
     */
    private fun sendInit(ws: WsConnection, key: RelayCrypto.PairingKey, nonce: ByteArray) {
        try {
            ws.sendBinary(RelayCrypto.initFrame(key, relay.room, nonce))
        } catch (e: IOException) {
            try {
                ws.setReadTimeout(500)
                val m = ws.receive()
                if (m is WsMessage.Closed) issue = issueOf(m.reason)
            } catch (_: IOException) {
            }
            throw e
        }
    }

    private fun issueOf(reason: String) = when (reason) {
        "join proof", "replaced" -> RelayIssue.ROOM_TAKEN
        "access key changed" -> RelayIssue.ACCESS_REFUSED
        else -> RelayIssue.UNREACHABLE
    }

    companion object {
        const val SUBPROTOCOL = "coucou.v1"
    }
}

/** The relay's text messages. They are hints for the status and the retry, never trusted for anything else. */
object RelayHints {
    enum class Hint { ONLINE, OFFLINE, OTHER }

    fun parse(text: String): Hint = when (text) {
        """{"peer":"online"}""" -> Hint.ONLINE
        """{"peer":"offline"}""" -> Hint.OFFLINE
        else -> Hint.OTHER
    }
}

/**
 * A [Socket] whose bytes are the encrypted v1 conversation through the relay. Whole lines are sealed and sent as one frame
 * each; frames that arrive are opened and handed to the reader as lines. Any fault (a bad tag, a wrong counter, a close) ends
 * the stream, and the [LinkClient] reconnects with a fresh handshake.
 */
class RelayStreamSocket(
    private val ws: WsConnection,
    private val session: RelayCrypto.Session,
) : Socket() {
    private val incoming = LinkedBlockingQueue<ByteArray>()
    @Volatile private var closed = false
    @Volatile private var timeoutMs = 0
    private var pending: ByteArray = EMPTY
    private var pendingAt = 0

    private val reader = Thread({ pump() }, "coucou-relay-reader").apply { isDaemon = true; start() }

    private fun pump() {
        try {
            while (!closed) {
                when (val m = ws.receive()) {
                    is WsMessage.Binary -> incoming.put(session.open(m.data) + NEWLINE)
                    is WsMessage.Text -> if (RelayHints.parse(m.text) == RelayHints.Hint.OFFLINE) break // the computer left: the conversation is over
                    is WsMessage.Closed -> break
                }
            }
        } catch (_: IOException) {
        } catch (_: RelayCrypto.ChannelException) {
        } finally {
            closed = true
            incoming.put(END)
        }
    }

    private val input = object : InputStream() {
        override fun read(): Int {
            val one = ByteArray(1)
            return if (read(one, 0, 1) < 0) -1 else one[0].toInt() and 0xFF
        }

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (len == 0) return 0
            if (pendingAt >= pending.size) {
                val next = if (timeoutMs > 0) incoming.poll(timeoutMs.toLong(), TimeUnit.MILLISECONDS) ?: throw SocketTimeoutException("read timed out") else incoming.take()
                if (next === END) {
                    incoming.put(END) // stays ended for later reads
                    return -1
                }
                pending = next
                pendingAt = 0
            }
            val n = minOf(len, pending.size - pendingAt)
            System.arraycopy(pending, pendingAt, b, off, n)
            pendingAt += n
            return n
        }
    }

    private val output = object : OutputStream() {
        private val line = java.io.ByteArrayOutputStream()

        override fun write(b: Int) = write(byteArrayOf(b.toByte()), 0, 1)

        @Synchronized override fun write(b: ByteArray, off: Int, len: Int) {
            if (closed) throw IOException("the relay connection is closed")
            for (i in off until off + len) {
                if (b[i] == '\n'.code.toByte()) {
                    val text = line.toByteArray()
                    line.reset()
                    try {
                        ws.sendBinary(session.seal(text))
                    } catch (e: RelayCrypto.ChannelException) {
                        throw IOException("could not seal a line (${e.failure})")
                    }
                } else {
                    if (line.size() >= RelayCrypto.MAX_LINE) throw IOException("line too long")
                    line.write(b[i].toInt())
                }
            }
        }
    }

    override fun getInputStream(): InputStream = input
    override fun getOutputStream(): OutputStream = output
    override fun setSoTimeout(timeout: Int) { timeoutMs = timeout }
    override fun getSoTimeout(): Int = timeoutMs
    override fun setTcpNoDelay(on: Boolean) {}
    override fun isConnected(): Boolean = !closed
    override fun isClosed(): Boolean = closed

    @Synchronized override fun close() {
        if (closed && !reader.isAlive) return
        closed = true
        runCatching { ws.close() }
        session.wipe()
        incoming.put(END)
    }

    private companion object {
        val EMPTY = ByteArray(0)
        val END = ByteArray(0)
        val NEWLINE = byteArrayOf('\n'.code.toByte())
    }
}
