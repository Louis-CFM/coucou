package com.coucou.android.link

import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * The relay connector against an in-memory stand-in for the relay + the computer: it speaks the WebSocket upgrade, plays
 * the computer's side of the end-to-end handshake with the same key, and lets each test misbehave in one way.
 */
class RelayConnectorTest {
    private val roomId = RelayCrypto.base64UrlEncode(ByteArray(16) { 5 })
    private val keyBytes = ByteArray(32) { 6 }
    private val accessKey = RelayCrypto.base64UrlEncode(ByteArray(32) { 7 })
    private val hostKey = RelayCrypto.PairingKey(keyBytes)
    private val pairing = RelayPairing("ws://127.0.0.1:8787", roomId, RelayCrypto.base64UrlEncode(keyBytes), accessKey)

    /** One direction of a connection: bytes put in come out in order; reads honour a timeout; a closed pipe ends reads and breaks writes. */
    private class Pipe {
        private val q = LinkedBlockingQueue<ByteArray>()
        private val end = ByteArray(0)
        @Volatile var timeoutMs = 0
        @Volatile private var closed = false
        private var current = end
        private var at = 0
        private var finished = false

        val out = object : OutputStream() {
            override fun write(b: Int) = write(byteArrayOf(b.toByte()), 0, 1)
            override fun write(b: ByteArray, off: Int, len: Int) {
                if (closed) throw IOException("Broken pipe")
                q.put(b.copyOfRange(off, off + len))
            }
        }

        val input = object : InputStream() {
            override fun read(): Int {
                val one = ByteArray(1)
                return if (read(one, 0, 1) < 0) -1 else one[0].toInt() and 0xFF
            }

            override fun read(b: ByteArray, off: Int, len: Int): Int {
                if (len == 0) return 0
                if (finished) return -1
                if (at >= current.size) {
                    val next = if (timeoutMs > 0) q.poll(timeoutMs.toLong(), TimeUnit.MILLISECONDS) ?: throw SocketTimeoutException("timeout") else q.take()
                    if (next === end) { finished = true; return -1 }
                    current = next
                    at = 0
                }
                val n = minOf(len, current.size - at)
                System.arraycopy(current, at, b, off, n)
                at += n
                return n
            }
        }

        fun close() {
            closed = true
            q.put(end)
        }
    }

    /** The phone's socket: it writes into [toRelay] and reads from [fromRelay]. */
    private class PipeSocket(val toRelay: Pipe, val fromRelay: Pipe) : Socket() {
        @Volatile private var closed = false
        override fun getInputStream(): InputStream = fromRelay.input
        override fun getOutputStream(): OutputStream = toRelay.out
        override fun setSoTimeout(timeout: Int) { fromRelay.timeoutMs = timeout }
        override fun setTcpNoDelay(on: Boolean) {}
        override fun isClosed() = closed
        override fun close() { closed = true; toRelay.close(); fromRelay.close() }
    }

    private enum class Mode { NORMAL, REFUSE_401, CLOSE_JOIN_PROOF, SILENT, WRONG_ACCEPT_FIRST, FAKE_COMPUTER }

    /** The relay (upgrade, frames) and the computer (end-to-end handshake) in one thread. */
    private inner class Fake(val mode: Mode = Mode.NORMAL) {
        private val toClient = Pipe()
        private val fromClient = Pipe()
        val socket = PipeSocket(fromClient, toClient)
        val headers = CopyOnWriteArrayList<String>()
        val inits = CopyOnWriteArrayList<ByteArray>()
        val lines = LinkedBlockingQueue<String>()
        @Volatile var session: RelayCrypto.Session? = null
        @Volatile var closedByClient = false
        private val ready = CountDownLatch(1)
        private val writeLock = Any()

        init {
            Thread({ run() }, "fake-relay").apply { isDaemon = true; start() }
        }

        private fun readHeaders(): String {
            val b = ByteArrayOutputStream()
            var last = 0
            while (true) {
                val x = fromClient.input.read()
                if (x < 0) throw EOFException()
                b.write(x)
                last = (last shl 8) or x
                if (last == 0x0D0A0D0A) return b.toString("ISO-8859-1")
            }
        }

        private fun write(bytes: ByteArray) = synchronized(writeLock) { toClient.out.write(bytes) }

        fun serverFrame(opcode: Int, payload: ByteArray, fin: Boolean = true): ByteArray {
            val out = ByteArrayOutputStream()
            out.write((if (fin) 0x80 else 0) or opcode)
            if (payload.size < 126) out.write(payload.size) else { out.write(126); out.write(payload.size ushr 8); out.write(payload.size and 0xFF) }
            out.write(payload)
            return out.toByteArray()
        }

        fun sendBinary(b: ByteArray) = write(serverFrame(WsOpcode.BINARY, b))
        fun sendText(t: String) = write(serverFrame(WsOpcode.TEXT, t.toByteArray()))
        fun sendClose(code: Int, reason: String) = write(serverFrame(WsOpcode.CLOSE, WsFrames.closePayload(code, reason)))
        fun sendLine(json: String) = sendBinary(session!!.seal(json.toByteArray()))
        fun awaitSession(): RelayCrypto.Session { ready.await(5, TimeUnit.SECONDS); return session!! }

        private fun readClientFrame(): Pair<Int, ByteArray> {
            val b0 = fromClient.input.read(); val b1 = fromClient.input.read()
            if (b0 < 0 || b1 < 0) throw EOFException()
            assertTrue("a client frame is masked", b1 and 0x80 != 0)
            var len = b1 and 0x7F
            if (len == 126) len = (fromClient.input.read() shl 8) or fromClient.input.read()
            val mask = ByteArray(4) { fromClient.input.read().toByte() }
            val payload = ByteArray(len)
            var got = 0
            while (got < len) { val r = fromClient.input.read(payload, got, len - got); if (r < 0) throw EOFException(); got += r }
            for (i in payload.indices) payload[i] = (payload[i].toInt() xor mask[i and 3].toInt()).toByte()
            return (b0 and 0x0F) to payload
        }

        private fun run() {
            try {
                val head = readHeaders()
                headers += head.split("\r\n")
                if (mode == Mode.REFUSE_401) { write("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n".toByteArray()); return }
                val key = head.lines().first { it.startsWith("Sec-WebSocket-Key:") }.substringAfter(":").trim()
                write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${WsHandshake.acceptFor(key)}\r\nSec-WebSocket-Protocol: coucou.v1\r\n\r\n").toByteArray())
                if (mode == Mode.CLOSE_JOIN_PROOF) { sendClose(1008, "join proof"); return }
                var wrongSent = false
                while (true) {
                    val (op, payload) = readClientFrame()
                    when (op) {
                        WsOpcode.CLOSE -> { closedByClient = true; return }
                        WsOpcode.BINARY -> if (payload.size > 1 && payload[1].toInt() == RelayCrypto.T_INIT) {
                            inits += payload
                            if (mode == Mode.SILENT) continue
                            if (mode == Mode.FAKE_COMPUTER) {
                                // Someone without K: a well-formed accept frame with a made-up nonce and MAC.
                                val junk = ByteArray(48).also { java.security.SecureRandom().nextBytes(it) }
                                sendBinary(byteArrayOf(RelayCrypto.VER.toByte(), RelayCrypto.T_ACCEPT.toByte(), 0, 0, 0, 0, 0, 0, 0, 0) + junk)
                                continue
                            }
                            if (mode == Mode.WRONG_ACCEPT_FIRST && !wrongSent) {
                                wrongSent = true
                                // An accept that answers some other init (a recorded one): the phone must ignore it.
                                val other = RelayCrypto.initFrame(hostKey, roomId, RelayCrypto.freshNonce())
                                sendBinary(RelayCrypto.acceptInit(hostKey, roomId, other, RelayCrypto.freshNonce()).first)
                            }
                            val (accept, s) = RelayCrypto.acceptInit(hostKey, roomId, payload, RelayCrypto.freshNonce())
                            session = s
                            sendBinary(accept)
                            ready.countDown()
                        } else {
                            lines.put(String(session!!.open(payload)))
                        }
                    }
                }
            } catch (_: IOException) {
            }
        }
    }

    private fun connectorFor(f: Fake, answerMs: Int = 5_000, resendMs: Int = 4_000) =
        RelayConnector(pairing, sockets = { _, _ -> f.socket }, answerTimeoutMs = answerMs, resendMs = resendMs)

    private fun readLine(s: Socket): String? {
        val b = ByteArrayOutputStream()
        while (true) {
            val x = s.getInputStream().read()
            if (x < 0) return null
            if (x == '\n'.code) return b.toString("UTF-8")
            b.write(x)
        }
    }

    // ── the upgrade ──

    @Test fun theUpgradePresentsTheAccessKeyTheJoinProofAndTheRoom() {
        val f = Fake()
        connectorFor(f).connect(2_000).close()
        val head = f.headers.joinToString("\n")
        assertTrue(head, f.headers[0] == "GET /v1/room/$roomId?role=phone HTTP/1.1")
        assertTrue(f.headers.contains("Authorization: Bearer $accessKey"))
        assertTrue(f.headers.contains("Sec-WebSocket-Protocol: coucou.v1, coucou.join.${RelayCrypto.joinProof(hostKey)}"))
        assertFalse("K itself is never sent", head.contains(pairing.key))
    }

    @Test fun theAccessKeyBeingRefusedIsReportedAsSuch() {
        val f = Fake(Mode.REFUSE_401)
        val c = connectorFor(f)
        try { c.connect(2_000); fail() } catch (e: WsHandshakeException) { assertEquals(401, e.status) }
        assertEquals(RelayIssue.ACCESS_REFUSED, c.issue)
    }

    @Test fun aRoomHeldBySomeoneElseIsReportedAsSuch() {
        val f = Fake(Mode.CLOSE_JOIN_PROOF)
        val c = connectorFor(f)
        try { c.connect(2_000); fail() } catch (_: IOException) {}
        assertEquals(RelayIssue.ROOM_TAKEN, c.issue)
    }

    @Test fun aComputerThatNeverAnswersIsAGiveUpAndInitIsAskedAgain() {
        val f = Fake(Mode.SILENT)
        val c = connectorFor(f, answerMs = 700, resendMs = 150)
        try { c.connect(2_000); fail() } catch (_: IOException) {}
        assertEquals(RelayIssue.COMPUTER_AWAY, c.issue)
        Thread.sleep(200) // the stand-in reads the last frames on its own thread
        val sent = f.inits.toList()
        assertTrue("init was sent again with a fresh nonce", sent.size >= 3)
        assertEquals("every init uses its own nonce", sent.size, sent.map { it.copyOfRange(10, 26).toList() }.toSet().size)
    }

    @Test fun aFakeComputerWithoutTheKeyIsNeverTrusted() {
        val f = Fake(Mode.FAKE_COMPUTER)
        val c = connectorFor(f, answerMs = 600, resendMs = 150)
        try { c.connect(2_000); fail("a made-up accept was accepted") } catch (_: IOException) {}
        assertEquals(RelayIssue.COMPUTER_AWAY, c.issue)
    }

    @Test fun anAcceptThatAnswersAnOtherInitIsIgnored() {
        val f = Fake(Mode.WRONG_ACCEPT_FIRST)
        val s = connectorFor(f).connect(2_000)
        s.getOutputStream().write("{\"type\":\"ping\"}\n".toByteArray())
        assertEquals("{\"type\":\"ping\"}", f.lines.poll(5, TimeUnit.SECONDS))
        s.close()
    }

    // ── the conversation ──

    @Test fun linesGoBothWaysEncryptedAndInOrder() {
        val f = Fake()
        val s = connectorFor(f).connect(2_000)
        val out = s.getOutputStream()
        out.write("{\"type\":\"hello\"}\n".toByteArray())
        out.write("{\"type\":\"ping\"}\n{\"type\":\"ping\"}\n".toByteArray())
        assertEquals("{\"type\":\"hello\"}", f.lines.poll(5, TimeUnit.SECONDS))
        assertEquals("{\"type\":\"ping\"}", f.lines.poll(5, TimeUnit.SECONDS))
        assertEquals("{\"type\":\"ping\"}", f.lines.poll(5, TimeUnit.SECONDS))
        f.awaitSession()
        f.sendLine("{\"type\":\"welcome\"}")
        f.sendLine("{\"type\":\"pong\"}")
        assertEquals("{\"type\":\"welcome\"}", readLine(s))
        assertEquals("{\"type\":\"pong\"}", readLine(s))
        s.close()
        assertTrue(s.isClosed)
    }

    @Test fun aLineOverTheLimitCannotBeSent() {
        val f = Fake()
        val s = connectorFor(f).connect(2_000)
        try { s.getOutputStream().write(ByteArray(RelayCrypto.MAX_LINE + 10) { 'a'.code.toByte() }); fail() } catch (_: IOException) {}
        s.close()
    }

    @Test fun aSilentLinkTimesOutLikeASocketWould() {
        val f = Fake()
        val s = connectorFor(f).connect(2_000)
        s.soTimeout = 150
        try { s.getInputStream().read(); fail() } catch (_: SocketTimeoutException) {}
        s.close()
    }

    @Test fun aTamperedReplayedOrReorderedFrameEndsTheStream() {
        for (what in listOf("flip", "replay", "gap")) {
            val f = Fake()
            val s = connectorFor(f).connect(2_000)
            val host = f.awaitSession()
            val first = host.seal("{\"n\":1}".toByteArray())
            when (what) {
                "flip" -> f.sendBinary(first.copyOf().also { it[it.size - 1] = (it[it.size - 1].toInt() xor 1).toByte() })
                "replay" -> { f.sendBinary(first); f.sendBinary(first) }
                "gap" -> { host.seal("{\"n\":2}".toByteArray()); f.sendBinary(host.seal("{\"n\":3}".toByteArray())) }
            }
            val got = mutableListOf<String?>()
            var line = readLine(s)
            while (line != null) { got += line; line = readLine(s) }
            assertTrue("$what: the stream ended", true)
            assertTrue("$what: at most the first line got through", got.size <= 1)
            assertTrue(got.all { it == "{\"n\":1}" })
            s.close()
        }
    }

    @Test fun theComputerLeavingEndsTheStream() {
        val f = Fake()
        val s = connectorFor(f).connect(2_000)
        f.awaitSession()
        f.sendText("""{"peer":"offline"}""")
        assertEquals(null, readLine(s))
        s.close()
    }

    @Test fun aCloseFromTheRelayEndsTheStream() {
        val f = Fake()
        val s = connectorFor(f).connect(2_000)
        f.sendClose(1008, "access key changed")
        assertEquals(null, readLine(s))
    }

    @Test fun closingTellsTheRelayAndNothingMoreCanBeSent() {
        val f = Fake()
        val s = connectorFor(f).connect(2_000)
        s.close()
        val deadline = System.currentTimeMillis() + 3_000
        while (!f.closedByClient && System.currentTimeMillis() < deadline) Thread.sleep(10)
        assertTrue(f.closedByClient)
        try { s.getOutputStream().write("x\n".toByteArray()); fail() } catch (_: IOException) {}
    }

    // ── the unchanged LinkClient on top ──

    @Test fun theLinkClientRunsTheUsualConversationThroughTheRelay() {
        val f = Fake()
        val welcome = CountDownLatch(1)
        val approval = LinkedBlockingQueue<ApprovalRequest>()
        val listener = object : LinkListener {
            override fun onWelcome(desktopName: String, os: String) { assertEquals("Test PC", desktopName); welcome.countDown() }
            override fun onApproval(request: ApprovalRequest) { approval.put(request) }
        }
        val payload = PairingPayload("192.0.2.1", 1, "ab".repeat(32), "tok_en-1234567890abcd", "PC", pairing)
        val client = LinkClient(payload, "Phone", listener, connector = connectorFor(f), caps = emptyList())
        client.start()
        try {
            val hello = JSONObject(f.lines.poll(5, TimeUnit.SECONDS))
            assertEquals("hello", hello.getString("type"))
            assertEquals("tok_en-1234567890abcd", hello.getString("token"))
            f.sendLine("""{"type":"welcome","v":1,"desktop":"Test PC","os":"linux"}""")
            assertTrue(welcome.await(5, TimeUnit.SECONDS))
            val fp = "cd".repeat(32)
            f.sendLine("""{"type":"approval","pillId":"integration_claude","tool":"Bash","command":"ls","fingerprint":"$fp","createdAt":${System.currentTimeMillis()}}""")
            val req = approval.poll(5, TimeUnit.SECONDS)
            assertNotNull(req)
            assertTrue(client.decide(fp, true))
            val decision = JSONObject(f.lines.poll(5, TimeUnit.SECONDS))
            assertEquals("decision", decision.getString("type"))
            assertEquals(fp, decision.getString("fingerprint"))
            assertEquals("allow", decision.getString("decision"))
        } finally {
            client.stop()
        }
    }
}
