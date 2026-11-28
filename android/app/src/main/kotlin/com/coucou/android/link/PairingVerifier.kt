package com.coucou.android.link

import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream

/**
 * Verifies a candidate [PairingPayload] by completing its pinned TLS handshake and exchanging
 * [ClientMsg.Hello] / [ServerMsg.Welcome] before an active pairing is torn down or overwritten.
 */
object PairingVerifier {
    const val DEFAULT_TIMEOUT_MS = 8_000

    sealed interface Result {
        data class Verified(val desktopName: String, val os: String) : Result
        data class Rejected(val reason: String) : Result
    }

    fun verify(
        pairing: PairingPayload,
        useRelay: Boolean,
        deviceName: String,
        timeoutMs: Int = DEFAULT_TIMEOUT_MS,
    ): Result {
        val lanTimeout = if (pairing.relay != null && useRelay) {
            minOf(timeoutMs, TransportPolicy.LAN_FAST_MS)
        } else {
            timeoutMs
        }
        val (lanResult, explicitReject) = verifyOnce(PinnedTls.connector(pairing), pairing.token, deviceName, lanTimeout)
        if (lanResult is Result.Verified || pairing.relay == null || !useRelay || explicitReject) {
            return lanResult
        }
        return verifyOnce(RelayConnector(pairing.relay), pairing.token, deviceName, timeoutMs).first
    }

    internal fun verifyWithConnector(
        connector: Connector,
        token: String,
        deviceName: String,
        timeoutMs: Int = DEFAULT_TIMEOUT_MS,
    ): Result = verifyOnce(connector, token, deviceName, timeoutMs).first

    private fun verifyOnce(
        connector: Connector,
        token: String,
        deviceName: String,
        timeoutMs: Int,
    ): Pair<Result, Boolean> {
        return try {
            connector.connect(timeoutMs).use { socket ->
                socket.soTimeout = timeoutMs
                socket.tcpNoDelay = true
                val out = socket.getOutputStream()
                val hello = Wire.encode(ClientMsg.Hello(Protocol.VERSION, token, deviceName, Protocol.CAPABILITIES)) + "\n"
                out.write(hello.toByteArray(Charsets.UTF_8))
                out.flush()

                val line = readBoundedLine(BufferedInputStream(socket.getInputStream()))
                    ?: return Result.Rejected("connection closed before welcome") to false
                when (val msg = Wire.decodeServer(line)) {
                    is ServerMsg.Welcome -> {
                        if (msg.version != Protocol.VERSION) {
                            Result.Rejected("unsupported protocol version") to true
                        } else {
                            runCatching {
                                out.write((Wire.encode(ClientMsg.Bye) + "\n").toByteArray(Charsets.UTF_8))
                                out.flush()
                            }
                            Result.Verified(msg.desktopName, msg.os) to false
                        }
                    }
                    is ServerMsg.Error -> Result.Rejected(msg.message.ifBlank { msg.code }) to true
                    else -> Result.Rejected("unexpected response") to true
                }
            }
        } catch (e: IOException) {
            Result.Rejected(e.message ?: "connection failed") to false
        }
    }

    private fun readBoundedLine(stream: InputStream): String? {
        val buf = ByteArrayOutputStream()
        while (true) {
            val b = stream.read()
            if (b < 0) return if (buf.size() == 0) null else buf.toString(Charsets.UTF_8.name()).trimEnd('\r')
            if (b == '\n'.code) return buf.toString(Charsets.UTF_8.name()).trimEnd('\r')
            if (buf.size() >= Protocol.MAX_LINE_BYTES) throw IOException("line too long")
            buf.write(b)
        }
    }
}
