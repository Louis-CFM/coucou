package com.coucou.android.link

import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.security.SecureRandom
import javax.net.ssl.SSLParameters
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

/**
 * A small WebSocket client (RFC 6455), written for exactly one job: the link to the user's own relay
 * (docs/RELAY_LINK.md). It has no dependency, speaks only what the relay needs (binary and text messages,
 * ping/pong, close, fragmentation) and refuses everything else. It was chosen over a library so that the app's
 * dependency list does not grow for the one feature that opens a connection to the internet (decision D2 of
 * android/RELAY_PLAN.md); OkHttp stays the fallback if this ever proves unreliable.
 *
 * The decoder never allocates more than [WsDecoder.maxMessage] bytes, whatever a frame header claims, and any rule
 * broken by the other side ends the connection with [WsProtocolException].
 */

class WsProtocolException(message: String) : IOException(message)

/** The upgrade was refused or answered wrongly. [status] is the HTTP status when there was one (401: access key, 429: rate limit, …). */
class WsHandshakeException(val status: Int, message: String) : IOException(message)

object WsOpcode {
    const val CONTINUATION = 0x0
    const val TEXT = 0x1
    const val BINARY = 0x2
    const val CLOSE = 0x8
    const val PING = 0x9
    const val PONG = 0xA
}

sealed class WsMessage {
    class Binary(val data: ByteArray) : WsMessage()
    class Text(val text: String) : WsMessage()
    /** The other side closed (or the connection ended cleanly). [code] is null when none was sent. */
    class Closed(val code: Int?, val reason: String) : WsMessage()
}

/** What the decoder found: either a message to hand on, a control frame to answer, or the end. */
sealed class WsEvent {
    class Message(val message: WsMessage) : WsEvent()
    class Ping(val payload: ByteArray) : WsEvent()
    object Pong : WsEvent()
}

object WsFrames {
    /** One complete, unfragmented, masked client frame. */
    fun encode(opcode: Int, payload: ByteArray, mask: ByteArray): ByteArray {
        require(mask.size == 4) { "a mask is 4 bytes" }
        require(opcode == WsOpcode.TEXT || opcode == WsOpcode.BINARY || opcode in WsOpcode.CLOSE..WsOpcode.PONG) { "opcode $opcode" }
        require(opcode < WsOpcode.CLOSE || payload.size <= 125) { "a control frame carries at most 125 bytes" }
        val out = ByteArrayOutputStream(payload.size + 14)
        out.write(0x80 or opcode)
        when {
            payload.size < 126 -> out.write(0x80 or payload.size)
            payload.size <= 0xFFFF -> {
                out.write(0x80 or 126)
                out.write(payload.size ushr 8)
                out.write(payload.size and 0xFF)
            }
            else -> {
                out.write(0x80 or 127)
                val n = payload.size.toLong()
                for (shift in 56 downTo 0 step 8) out.write(((n ushr shift) and 0xFF).toInt())
            }
        }
        out.write(mask)
        val masked = ByteArray(payload.size) { (payload[it].toInt() xor mask[it and 3].toInt()).toByte() }
        out.write(masked)
        return out.toByteArray()
    }

    fun closePayload(code: Int, reason: String = ""): ByteArray {
        val r = reason.toByteArray(Charsets.UTF_8).let { if (it.size > 123) it.copyOf(123) else it }
        return byteArrayOf((code ushr 8).toByte(), code.toByte()) + r
    }
}

/** Reads server frames. Not thread-safe: one reader. */
class WsDecoder(private val input: InputStream, val maxMessage: Int) {
    private var fragments: ByteArrayOutputStream? = null
    private var fragmentOpcode = 0

    private fun readFully(n: Int): ByteArray {
        val buf = ByteArray(n)
        var got = 0
        while (got < n) {
            val r = input.read(buf, got, n - got)
            if (r < 0) throw EOFException("the connection ended")
            got += r
        }
        return buf
    }

    private fun readByte(): Int {
        val b = input.read()
        if (b < 0) throw EOFException("the connection ended")
        return b
    }

    /** Blocks for the next event. Throws [EOFException] when the stream ends, [WsProtocolException] when the server breaks a rule. */
    fun next(): WsEvent {
        while (true) {
            val b0 = readByte()
            val b1 = readByte()
            val fin = b0 and 0x80 != 0
            if (b0 and 0x70 != 0) throw WsProtocolException("reserved bits set")
            val opcode = b0 and 0x0F
            if (b1 and 0x80 != 0) throw WsProtocolException("a server frame must not be masked")
            var length = (b1 and 0x7F).toLong()
            if (length == 126L) {
                length = ((readByte() shl 8) or readByte()).toLong()
            } else if (length == 127L) {
                length = 0
                for (i in 0 until 8) length = (length shl 8) or readByte().toLong()
                if (length < 0) throw WsProtocolException("length out of range")
            }
            val control = opcode >= WsOpcode.CLOSE
            if (control && (!fin || length > 125)) throw WsProtocolException("bad control frame")
            if (opcode != WsOpcode.CONTINUATION && opcode != WsOpcode.TEXT && opcode != WsOpcode.BINARY && !control) {
                throw WsProtocolException("unknown opcode")
            }
            if (control && opcode !in WsOpcode.CLOSE..WsOpcode.PONG) throw WsProtocolException("unknown opcode")
            // Checked before anything is allocated or read: a header cannot make us buffer more than the limit.
            val already = fragments?.size()?.toLong() ?: 0L
            if (!control && already + length > maxMessage) throw WsProtocolException("message too large")
            val payload = readFully(length.toInt())

            when (opcode) {
                WsOpcode.PING -> return WsEvent.Ping(payload)
                WsOpcode.PONG -> return WsEvent.Pong
                WsOpcode.CLOSE -> return WsEvent.Message(closeOf(payload))
                WsOpcode.TEXT, WsOpcode.BINARY -> {
                    if (fragments != null) throw WsProtocolException("a new message started inside another")
                    if (fin) return WsEvent.Message(message(opcode, payload))
                    fragments = ByteArrayOutputStream().also { it.write(payload) }
                    fragmentOpcode = opcode
                }
                else -> { // continuation
                    val parts = fragments ?: throw WsProtocolException("continuation without a start")
                    parts.write(payload)
                    if (fin) {
                        fragments = null
                        return WsEvent.Message(message(fragmentOpcode, parts.toByteArray()))
                    }
                }
            }
        }
    }

    private fun message(opcode: Int, payload: ByteArray): WsMessage =
        if (opcode == WsOpcode.BINARY) WsMessage.Binary(payload) else WsMessage.Text(utf8(payload))

    private fun closeOf(payload: ByteArray): WsMessage.Closed {
        if (payload.isEmpty()) return WsMessage.Closed(null, "")
        if (payload.size == 1) throw WsProtocolException("a close frame cannot carry one byte")
        val code = ((payload[0].toInt() and 0xFF) shl 8) or (payload[1].toInt() and 0xFF)
        val valid = code in 1000..1003 || code in 1007..1011 || code in 3000..4999
        if (!valid) throw WsProtocolException("bad close code")
        return WsMessage.Closed(code, utf8(payload.copyOfRange(2, payload.size)))
    }

    private fun utf8(bytes: ByteArray): String = try {
        Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes)).toString()
    } catch (_: CharacterCodingException) {
        throw WsProtocolException("text is not valid UTF-8")
    }
}

object WsHandshake {
    private const val GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    const val MAX_HEADER_BYTES = 8192

    fun newKey(random: SecureRandom = SecureRandom()): String =
        java.util.Base64.getEncoder().encodeToString(ByteArray(16).also(random::nextBytes))

    fun acceptFor(key: String): String =
        java.util.Base64.getEncoder().encodeToString(MessageDigest.getInstance("SHA-1").digest((key + GUID).toByteArray(Charsets.US_ASCII)))

    /** The upgrade request. Header values may not contain line breaks. */
    fun request(hostHeader: String, path: String, key: String, headers: List<Pair<String, String>>): ByteArray {
        val all = listOf("Host" to hostHeader, "Upgrade" to "websocket", "Connection" to "Upgrade", "Sec-WebSocket-Key" to key, "Sec-WebSocket-Version" to "13") + headers
        require(path.startsWith("/") && path.none { it == '\r' || it == '\n' || it == ' ' }) { "bad path" }
        val sb = StringBuilder("GET $path HTTP/1.1\r\n")
        for ((name, value) in all) {
            require(name.isNotEmpty() && (name + value).none { it == '\r' || it == '\n' || it == '\u0000' }) { "bad header" }
            sb.append(name).append(": ").append(value).append("\r\n")
        }
        return sb.append("\r\n").toString().toByteArray(Charsets.US_ASCII)
    }

    /**
     * Reads the response up to the blank line (byte by byte, so no frame data is swallowed) and checks it. Returns the
     * sub-protocol the server chose. Anything but a correct 101 throws [WsHandshakeException] with the status.
     */
    fun readResponse(input: InputStream, key: String, offeredProtocols: Set<String>): String? {
        val head = ByteArrayOutputStream()
        var last4 = 0
        while (true) {
            val b = input.read()
            if (b < 0) throw WsHandshakeException(0, "the connection ended during the upgrade")
            head.write(b)
            if (head.size() > MAX_HEADER_BYTES) throw WsHandshakeException(0, "the response is too long")
            last4 = (last4 shl 8) or b
            if (last4 == 0x0D0A0D0A) break
        }
        val lines = head.toString(Charsets.ISO_8859_1.name()).split("\r\n").filter { it.isNotEmpty() }
        val status = lines.firstOrNull()?.split(" ")?.takeIf { it.size >= 2 && it[0].startsWith("HTTP/1.") }?.get(1)?.toIntOrNull()
            ?: throw WsHandshakeException(0, "not an HTTP response")
        if (status != 101) throw WsHandshakeException(status, "the upgrade was refused ($status)")
        val h = HashMap<String, String>()
        for (line in lines.drop(1)) {
            val i = line.indexOf(':')
            if (i <= 0) throw WsHandshakeException(status, "bad header")
            h[line.substring(0, i).trim().lowercase()] = line.substring(i + 1).trim()
        }
        if (h["upgrade"]?.lowercase() != "websocket") throw WsHandshakeException(status, "not a websocket upgrade")
        if (h["connection"]?.lowercase()?.split(",")?.map { it.trim() }?.contains("upgrade") != true) throw WsHandshakeException(status, "not an upgrade")
        if (h["sec-websocket-accept"] != acceptFor(key)) throw WsHandshakeException(status, "wrong accept value")
        val chosen = h["sec-websocket-protocol"]
        if (offeredProtocols.isNotEmpty() && chosen !in offeredProtocols) throw WsHandshakeException(status, "no agreed sub-protocol")
        if (offeredProtocols.isEmpty() && chosen != null) throw WsHandshakeException(status, "unrequested sub-protocol")
        if (h["sec-websocket-extensions"] != null) throw WsHandshakeException(status, "unrequested extension")
        return chosen
    }
}

/** An open connection. Sending is thread-safe; receiving is for one thread. */
class WsConnection(
    private val socket: Socket,
    input: InputStream,
    private val output: OutputStream,
    maxMessage: Int,
    private val random: SecureRandom = SecureRandom(),
) : Closeable {
    private val decoder = WsDecoder(input, maxMessage)
    private val writeLock = Any()
    @Volatile private var closeSent = false

    private fun sendFrame(opcode: Int, payload: ByteArray) {
        val mask = ByteArray(4).also(random::nextBytes)
        val frame = WsFrames.encode(opcode, payload, mask)
        synchronized(writeLock) {
            output.write(frame)
            output.flush()
        }
    }

    fun sendBinary(data: ByteArray) = sendFrame(WsOpcode.BINARY, data)

    /** Waits for the next binary or text message (pings are answered, pongs ignored). A close from the other side is returned once. */
    fun receive(): WsMessage {
        while (true) {
            when (val e = decoder.next()) {
                is WsEvent.Ping -> sendFrame(WsOpcode.PONG, e.payload)
                WsEvent.Pong -> {}
                is WsEvent.Message -> {
                    val m = e.message
                    if (m is WsMessage.Closed) {
                        runCatching { sendClose(m.code ?: 1000, "") }
                    }
                    return m
                }
            }
        }
    }

    private fun sendClose(code: Int, reason: String) {
        if (closeSent) return
        closeSent = true
        sendFrame(WsOpcode.CLOSE, WsFrames.closePayload(code, reason))
    }

    fun setReadTimeout(ms: Int) {
        socket.soTimeout = ms
    }

    override fun close() {
        runCatching { sendClose(1000, "") }
        runCatching { socket.close() }
    }
}

/** Where a relay is: the host and port of a `wss://` address (or `ws://` to this same computer, for tests and development). */
data class RelayUrl(val tls: Boolean, val host: String, val port: Int) {
    val display: String get() = "${if (tls) "wss" else "ws"}://$host" + if (port == (if (tls) 443 else 80)) "" else ":$port"

    companion object {
        /** Accepts only `wss://host[:port]`; `ws://` only to localhost. No path, query, fragment or credentials. */
        fun parse(text: String): RelayUrl? {
            val t = text.trim()
            val tls = when {
                t.startsWith("wss://") -> true
                t.startsWith("ws://") -> false
                else -> return null
            }
            var rest = t.substringAfter("://").removeSuffix("/")
            if (rest.isEmpty() || rest.any { it in "/?#@ \\" || it.code < 0x21 || it.code > 0x7E }) return null
            var port = if (tls) 443 else 80
            val host: String
            if (rest.startsWith("[")) {
                val end = rest.indexOf(']')
                if (end < 0) return null
                host = rest.substring(0, end + 1)
                val tail = rest.substring(end + 1)
                if (tail.isNotEmpty()) port = tail.removePrefix(":").toIntOrNull() ?: return null
                if (tail.isNotEmpty() && !tail.startsWith(":")) return null
                if (host != "[::1]") return null
            } else {
                val colon = rest.lastIndexOf(':')
                if (colon >= 0) {
                    port = rest.substring(colon + 1).toIntOrNull() ?: return null
                    rest = rest.substring(0, colon)
                }
                host = rest
                if (host.isEmpty() || host.length > 253 || host.startsWith(".") || host.startsWith("-") || host.contains("..") ||
                    !host.all { it.isLetterOrDigit() && it.code < 0x80 || it == '.' || it == '-' }
                ) return null
            }
            if (port !in 1..65535) return null
            if (!tls && host != "localhost" && host != "127.0.0.1" && host != "[::1]") return null
            return RelayUrl(tls, host, port)
        }
    }
}

object WsClient {
    const val HANDSHAKE_TIMEOUT_MS = 10_000

    /**
     * Opens a WebSocket to [url] at [path] with the given extra headers. TLS uses the system's trust store and checks the
     * host name. Throws [WsHandshakeException] when the server answers but refuses, [IOException] when it cannot be reached.
     */
    fun open(
        url: RelayUrl,
        path: String,
        headers: List<Pair<String, String>>,
        protocols: List<String>,
        connectTimeoutMs: Int,
        maxMessage: Int,
        sockets: (RelayUrl, Int) -> Socket = ::defaultSocket,
    ): WsConnection {
        val socket = sockets(url, connectTimeoutMs)
        try {
            socket.soTimeout = HANDSHAKE_TIMEOUT_MS
            socket.tcpNoDelay = true
            val key = WsHandshake.newKey()
            val hostHeader = if (url.port == (if (url.tls) 443 else 80)) url.host else "${url.host}:${url.port}"
            val extra = headers + if (protocols.isEmpty()) emptyList() else listOf("Sec-WebSocket-Protocol" to protocols.joinToString(", "))
            val out = socket.getOutputStream()
            out.write(WsHandshake.request(hostHeader, path, key, extra))
            out.flush()
            val input = java.io.BufferedInputStream(socket.getInputStream())
            WsHandshake.readResponse(input, key, if (protocols.isEmpty()) emptySet() else setOf(protocols.first()))
            return WsConnection(socket, input, out, maxMessage)
        } catch (e: Throwable) {
            runCatching { socket.close() }
            throw e
        }
    }

    val defaultSockets: (RelayUrl, Int) -> Socket = ::defaultSocket

    private fun defaultSocket(url: RelayUrl, timeoutMs: Int): Socket {
        val raw = Socket()
        raw.connect(InetSocketAddress(url.host.trim('[', ']'), url.port), timeoutMs)
        if (!url.tls) return raw
        val tls = (SSLSocketFactory.getDefault() as SSLSocketFactory).createSocket(raw, url.host, url.port, true) as SSLSocket
        tls.enabledProtocols = tls.supportedProtocols.filter { it == "TLSv1.3" || it == "TLSv1.2" }.toTypedArray()
        tls.sslParameters = tls.sslParameters.also { p: SSLParameters -> p.endpointIdentificationAlgorithm = "HTTPS" }
        tls.soTimeout = HANDSHAKE_TIMEOUT_MS
        tls.startHandshake()
        return tls
    }
}
