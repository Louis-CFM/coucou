package com.coucou.android.link

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.util.Random
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** The in-house WebSocket client (decision D2): framing, masking, fragmentation, size limits and a fuzz run. */
class WebSocketTest {
    private fun hex(s: String) = s.replace(" ", "").chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    private fun decoder(bytes: ByteArray, max: Int = 1024) = WsDecoder(ByteArrayInputStream(bytes), max)

    /** What a server sends: not masked. */
    private fun serverFrame(opcode: Int, payload: ByteArray, fin: Boolean = true): ByteArray {
        val out = ByteArrayOutputStream()
        out.write((if (fin) 0x80 else 0) or opcode)
        when {
            payload.size < 126 -> out.write(payload.size)
            payload.size <= 0xFFFF -> { out.write(126); out.write(payload.size ushr 8); out.write(payload.size and 0xFF) }
            else -> { out.write(127); for (s in 56 downTo 0 step 8) out.write(((payload.size.toLong() ushr s) and 0xFF).toInt()) }
        }
        out.write(payload)
        return out.toByteArray()
    }

    private fun message(e: WsEvent) = (e as WsEvent.Message).message

    // ── masking and encoding (RFC 6455 section 5.7 examples) ──

    @Test fun aMaskedClientFrameMatchesTheRfcExample() {
        val frame = WsFrames.encode(WsOpcode.TEXT, "Hello".toByteArray(), hex("37fa213d"))
        assertArrayEquals(hex("81 85 37fa213d 7f9f4d5158"), frame)
    }

    @Test fun everyClientFrameIsMaskedAndTheMaskIsFresh() {
        val a = WsFrames.encode(WsOpcode.BINARY, ByteArray(10), hex("01020304"))
        assertTrue("the mask bit is set", a[1].toInt() and 0x80 != 0)
        assertFalse("the payload is not sent in clear", a.copyOfRange(6, 16).all { it == 0.toByte() })
        val link = WsConnectionProbe.maskedFramesDiffer()
        assertTrue("two frames of the same data use different masks", link)
    }

    @Test fun lengthsAroundTheBoundariesRoundTrip() {
        for (n in listOf(0, 1, 124, 125, 126, 127, 65535, 65536, 70000)) {
            val payload = ByteArray(n) { (it * 7).toByte() }
            val enc = WsFrames.encode(WsOpcode.BINARY, payload, hex("a1b2c3d4"))
            // Unmask what we encoded, by the rules a server follows, and read it back.
            val headerLen = 2 + (if (n < 126) 0 else if (n <= 0xFFFF) 2 else 8)
            val unmasked = ByteArray(n) { (enc[headerLen + 4 + it].toInt() xor "a1b2c3d4".chunked(2).map { h -> h.toInt(16) }[it and 3]).toByte() }
            assertArrayEquals(payload, unmasked)
            val e = decoder(serverFrame(WsOpcode.BINARY, payload), max = 100_000).next()
            assertArrayEquals(payload, (message(e) as WsMessage.Binary).data)
        }
    }

    @Test fun aControlFrameOver125BytesCannotBeEncoded() {
        try { WsFrames.encode(WsOpcode.PING, ByteArray(126), ByteArray(4)); fail() } catch (_: IllegalArgumentException) {}
    }

    // ── decoding ──

    @Test fun textAndBinaryMessagesAreDecoded() {
        assertEquals("Hello", (message(decoder(hex("81 05 48656c6c6f")).next()) as WsMessage.Text).text)
        assertArrayEquals(byteArrayOf(1, 2, 3), (message(decoder(serverFrame(WsOpcode.BINARY, byteArrayOf(1, 2, 3))).next()) as WsMessage.Binary).data)
    }

    @Test fun fragmentedMessagesAreReassembledEvenWithAPingBetween() {
        val bytes = serverFrame(WsOpcode.TEXT, "Hel".toByteArray(), fin = false) +
            serverFrame(WsOpcode.PING, byteArrayOf(9)) +
            serverFrame(WsOpcode.CONTINUATION, "lo".toByteArray(), fin = true)
        val d = decoder(bytes)
        val ping = d.next()
        assertTrue(ping is WsEvent.Ping && ping.payload.contentEquals(byteArrayOf(9)))
        assertEquals("Hello", (message(d.next()) as WsMessage.Text).text)
    }

    @Test fun aMultiByteCharacterSplitAcrossFragmentsIsNotCorrupted() {
        val euro = "€".toByteArray() // 3 bytes
        val bytes = serverFrame(WsOpcode.TEXT, euro.copyOfRange(0, 1), fin = false) + serverFrame(WsOpcode.CONTINUATION, euro.copyOfRange(1, 3))
        assertEquals("€", (message(decoder(bytes).next()) as WsMessage.Text).text)
    }

    @Test fun theRulesTheServerMustKeepAreEnforced() {
        val bad = mapOf(
            "masked server frame" to hex("81 85 37fa213d 7f9f4d5158"),
            "reserved bit" to hex("c1 05 48656c6c6f"),
            "fragmented control frame" to hex("09 00"),
            "control frame over 125" to (byteArrayOf(0x89.toByte(), 126, 0, 126) + ByteArray(126)),
            "unknown data opcode" to hex("83 00"),
            "unknown control opcode" to hex("8b 00"),
            "continuation without a start" to hex("80 01 41"),
            "a message inside a message" to (serverFrame(WsOpcode.TEXT, byteArrayOf(65), fin = false) + serverFrame(WsOpcode.TEXT, byteArrayOf(66))),
            "text that is not UTF-8" to serverFrame(WsOpcode.TEXT, byteArrayOf(0xC3.toByte(), 0x28)),
            "close with one byte" to serverFrame(WsOpcode.CLOSE, byteArrayOf(3)),
            "close code 1005" to serverFrame(WsOpcode.CLOSE, byteArrayOf(0x03, 0xED.toByte())),
            "close code 999" to serverFrame(WsOpcode.CLOSE, byteArrayOf(0x03, 0xE7.toByte())),
            "64-bit length with the top bit" to hex("82 7f 8000000000000000"),
        )
        for ((name, bytes) in bad) {
            try { decoder(bytes).next(); fail("$name was accepted") } catch (_: WsProtocolException) {}
        }
    }

    @Test fun aHugeLengthIsRefusedBeforeAnythingIsAllocatedOrRead() {
        // The header claims 1 GiB; the stream holds nothing more. A protocol error, not an out-of-memory or a long wait.
        try { decoder(hex("82 7f 0000000040000000")).next(); fail() } catch (_: WsProtocolException) {}
        try { decoder(hex("82 7f 00000000ffffffff"), max = 66_000).next(); fail() } catch (_: WsProtocolException) {}
        // A message over the limit, even in small fragments.
        val parts = ByteArrayOutputStream()
        parts.write(serverFrame(WsOpcode.BINARY, ByteArray(600), fin = false))
        parts.write(serverFrame(WsOpcode.CONTINUATION, ByteArray(600), fin = true))
        try { decoder(parts.toByteArray(), max = 1000).next(); fail() } catch (_: WsProtocolException) {}
    }

    @Test fun aMessageExactlyAtTheLimitIsAccepted() {
        val e = decoder(serverFrame(WsOpcode.BINARY, ByteArray(1000)), max = 1000).next()
        assertEquals(1000, (message(e) as WsMessage.Binary).data.size)
    }

    @Test fun aTruncatedStreamIsAnEndOfStreamNotAHang() {
        for (cut in 1 until 10) {
            val full = serverFrame(WsOpcode.TEXT, "Hello".toByteArray())
            try { decoder(full.copyOf(minOf(cut, full.size - 1))).next(); fail("cut $cut") } catch (_: EOFException) {}
        }
    }

    @Test fun closeFramesCarryTheirCodeAndReason() {
        val m = message(decoder(serverFrame(WsOpcode.CLOSE, WsFrames.closePayload(1008, "join proof"))).next()) as WsMessage.Closed
        assertEquals(1008, m.code)
        assertEquals("join proof", m.reason)
        val none = message(decoder(serverFrame(WsOpcode.CLOSE, ByteArray(0))).next()) as WsMessage.Closed
        assertNull(none.code)
    }

    // ── a malformed-input fuzz run ──

    @Test fun randomBytesNeverCrashTheDecoderAndNeverBufferMoreThanTheLimit() {
        val rnd = Random(20260101)
        val limit = 2048
        var accepted = 0
        repeat(30_000) {
            val bytes = ByteArray(rnd.nextInt(80)).also(rnd::nextBytes)
            val d = WsDecoder(ByteArrayInputStream(bytes), limit)
            try {
                while (true) {
                    when (val e = d.next()) {
                        is WsEvent.Message -> {
                            accepted++
                            val m = e.message
                            if (m is WsMessage.Binary) assertTrue(m.data.size <= limit)
                            if (m is WsMessage.Text) assertTrue(m.text.length <= limit)
                        }
                        else -> {}
                    }
                }
            } catch (_: WsProtocolException) {
            } catch (_: EOFException) {
            }
        }
        assertTrue("the fuzz inputs reached some valid frames too", accepted > 0)
    }

    @Test fun flippedBitsInValidFramesNeverEscapeAsAnythingButAProtocolError() {
        val rnd = Random(7)
        val valid = serverFrame(WsOpcode.TEXT, "Hel".toByteArray(), fin = false) + serverFrame(WsOpcode.PING, byteArrayOf(1, 2)) +
            serverFrame(WsOpcode.CONTINUATION, "lo".toByteArray()) + serverFrame(WsOpcode.BINARY, ByteArray(200) { it.toByte() }) +
            serverFrame(WsOpcode.CLOSE, WsFrames.closePayload(1000, "bye"))
        repeat(20_000) {
            val bytes = valid.copyOf()
            repeat(1 + rnd.nextInt(4)) { bytes[rnd.nextInt(bytes.size)] = (bytes[rnd.nextInt(bytes.size)].toInt() xor (1 shl rnd.nextInt(8))).toByte() }
            val d = WsDecoder(ByteArrayInputStream(bytes), 4096)
            try { while (true) d.next() } catch (_: WsProtocolException) {} catch (_: EOFException) {}
        }
    }

    // ── the upgrade ──

    @Test fun theAcceptValueMatchesTheRfcExample() {
        assertEquals("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", WsHandshake.acceptFor("dGhlIHNhbXBsZSBub25jZQ=="))
    }

    @Test fun theRequestCarriesTheHeadersAndRefusesLineBreaks() {
        val req = String(WsHandshake.request("relay.example.com", "/v1/room/AAAAAAAAAAAAAAAAAAAAAA?role=phone", "KEY", listOf("Authorization" to "Bearer abc", "Sec-WebSocket-Protocol" to "coucou.v1, coucou.join.x")))
        assertTrue(req.startsWith("GET /v1/room/AAAAAAAAAAAAAAAAAAAAAA?role=phone HTTP/1.1\r\nHost: relay.example.com\r\n"))
        assertTrue(req.contains("Upgrade: websocket\r\n") && req.contains("Sec-WebSocket-Version: 13\r\n") && req.contains("Authorization: Bearer abc\r\n"))
        assertTrue(req.endsWith("\r\n\r\n"))
        for (bad in listOf("a\r\nX: y", "a\nb", "a\u0000b")) {
            try { WsHandshake.request("h", "/", "k", listOf("X" to bad)); fail() } catch (_: IllegalArgumentException) {}
        }
        try { WsHandshake.request("h", "/a b", "k", emptyList()); fail() } catch (_: IllegalArgumentException) {}
    }

    private fun response(status: String = "101 Switching Protocols", key: String = "KEY", extra: String = "", accept: String = WsHandshake.acceptFor("KEY"), protocol: String? = "coucou.v1"): ByteArray =
        ("HTTP/1.1 $status\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: $accept\r\n" +
            (protocol?.let { "Sec-WebSocket-Protocol: $it\r\n" } ?: "") + extra + "\r\n").toByteArray()

    @Test fun aCorrectResponseIsAcceptedAndNoFrameDataIsSwallowed() {
        val after = byteArrayOf(0x81.toByte(), 2, 'o'.code.toByte(), 'k'.code.toByte())
        val input = ByteArrayInputStream(response() + after)
        assertEquals("coucou.v1", WsHandshake.readResponse(input, "KEY", setOf("coucou.v1")))
        assertEquals("ok", (message(WsDecoder(input, 100).next()) as WsMessage.Text).text)
    }

    @Test fun everyWrongResponseIsRefusedWithItsStatus() {
        fun status(bytes: ByteArray) = try { WsHandshake.readResponse(ByteArrayInputStream(bytes), "KEY", setOf("coucou.v1")); -1 } catch (e: WsHandshakeException) { e.status }
        assertEquals(401, status("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n".toByteArray()))
        assertEquals(429, status("HTTP/1.1 429 Too Many Requests\r\n\r\n".toByteArray()))
        assertEquals(404, status("HTTP/1.1 404 Not Found\r\n\r\n".toByteArray()))
        assertEquals(101, status(response(accept = "wrong")))
        assertEquals(101, status(response(protocol = "other")))
        assertEquals(101, status(response(protocol = null)))
        assertEquals(101, status(response(extra = "Sec-WebSocket-Extensions: permessage-deflate\r\n")))
        assertEquals(101, status("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${WsHandshake.acceptFor("KEY")}\r\nSec-WebSocket-Protocol: coucou.v1\r\n\r\n".toByteArray()))
        assertEquals(0, status("garbage\r\n\r\n".toByteArray()))
        assertEquals(0, status("HTTP/1.1 101".toByteArray()))
        assertEquals(0, status(ByteArray(WsHandshake.MAX_HEADER_BYTES + 100) { 'a'.code.toByte() }))
    }

    // ── relay addresses ──

    @Test fun onlyAWssAddressWithNothingElseIsAccepted() {
        assertEquals(RelayUrl(true, "relay.example.workers.dev", 443), RelayUrl.parse("wss://relay.example.workers.dev"))
        assertEquals(RelayUrl(true, "relay.example.com", 8443), RelayUrl.parse(" wss://relay.example.com:8443/ "))
        assertEquals("wss://relay.example.com:8443", RelayUrl.parse("wss://relay.example.com:8443")!!.display)
        assertEquals("wss://relay.example.com", RelayUrl.parse("wss://relay.example.com")!!.display)
        assertEquals(RelayUrl(false, "127.0.0.1", 8787), RelayUrl.parse("ws://127.0.0.1:8787"))
        assertEquals(RelayUrl(false, "localhost", 8787), RelayUrl.parse("ws://localhost:8787"))
        for (bad in listOf(
            "", "relay.example.com", "https://relay.example.com", "ws://relay.example.com", "ws://192.168.1.5:8787", "wss://",
            "wss://user:pw@relay.example.com", "wss://relay.example.com/path", "wss://relay.example.com/?x=1", "wss://relay.example.com#f",
            "wss://relay example.com", "wss://-bad.example.com", "wss://a..b", "wss://relay.example.com:0", "wss://relay.example.com:99999",
            "wss://relay.example.com:", "wss://rélay.example.com", "wss://relay.example.com\\x",
        )) assertNull("$bad must be refused", RelayUrl.parse(bad))
    }
}

/** Two frames of the same payload must not carry the same mask (the client draws a new one for each). */
private object WsConnectionProbe {
    fun maskedFramesDiffer(): Boolean {
        val written = ByteArrayOutputStream()
        val conn = WsConnection(java.net.Socket(), ByteArrayInputStream(ByteArray(0)), written, 1024, java.security.SecureRandom())
        repeat(8) { conn.sendBinary(ByteArray(4)) }
        val bytes = written.toByteArray()
        val masks = (0 until 8).map { bytes.copyOfRange(it * 10 + 2, it * 10 + 6).toList() }
        return masks.toSet().size > 1
    }
}
