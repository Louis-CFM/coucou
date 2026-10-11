package com.coucou.android.link

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.net.Socket
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test

/**
 * The WebSocket client and the connector against a real server: the relay's Node twin (android/relay/tools/dev-relay.ts,
 * the same rules as the Cloudflare Worker, from the same code). It is a separate implementation of WebSocket (the `ws`
 * package), so it checks this client's framing, masking and upgrade against someone else's reading of RFC 6455.
 *
 * Runs only when COUCOU_NODE_RELAY=1 and `npm ci` was done in android/relay (CI does both).
 */
class RelayNodeTwinTest {
    private var process: Process? = null
    private var port = 0
    private val access = RelayCrypto.base64UrlEncode(ByteArray(32) { 9 })
    private val room = RelayCrypto.base64UrlEncode(ByteArray(16) { 4 })
    private val key = RelayCrypto.PairingKey(ByteArray(32) { 8 })

    @Before fun start() {
        assumeTrue("set COUCOU_NODE_RELAY=1 to run against the relay's Node twin", System.getenv("COUCOU_NODE_RELAY") == "1")
        val script = listOf(File("../relay/tools/dev-relay.ts"), File("android/relay/tools/dev-relay.ts")).first { it.exists() }
        val node = ProcessBuilder("node", "--experimental-strip-types", "--no-warnings", script.path)
            .also { it.environment().putAll(mapOf("ACCESS_KEY" to access, "PORT" to "0", "HOST" to "127.0.0.1")) }
            .redirectErrorStream(true)
            .start()
        process = node
        val first = node.inputStream.bufferedReader().readLine() ?: error("the relay printed nothing")
        port = Regex("port (\\d+)").find(first)!!.groupValues[1].toInt()
    }

    @After fun stop() { process?.destroy() }

    private fun pairing(accessKey: String = access, k: RelayCrypto.PairingKey = key) =
        RelayPairing("ws://127.0.0.1:$port", room, k.toBase64Url(), accessKey)

    /** The computer's side: joins as `pc`, answers `init`, and exchanges lines. */
    private inner class Host(k: RelayCrypto.PairingKey = key) : AutoCloseable {
        val ws: WsConnection = WsClient.open(
            RelayUrl.parse("ws://127.0.0.1:$port")!!, "/v1/room/$room?role=pc",
            listOf("Authorization" to "Bearer $access"), listOf("coucou.v1", "coucou.join.${RelayCrypto.joinProof(k)}"),
            3_000, RelayCrypto.MAX_FRAME + 1024,
        )
        val lines = LinkedBlockingQueue<String>()
        @Volatile var session: RelayCrypto.Session? = null
        @Volatile var peerOffline = false

        init {
            Thread({
                try {
                    while (true) when (val m = ws.receive()) {
                        is WsMessage.Binary -> {
                            val f = m.data
                            if (f.size > 1 && f[1].toInt() == RelayCrypto.T_INIT) {
                                val (accept, s) = RelayCrypto.acceptInit(k, room, f, RelayCrypto.freshNonce())
                                session = s
                                ws.sendBinary(accept)
                            } else lines.put(String(session!!.open(f)))
                        }
                        is WsMessage.Text -> if (RelayHints.parse(m.text) == RelayHints.Hint.OFFLINE) peerOffline = true
                        is WsMessage.Closed -> return@Thread
                    }
                } catch (_: Exception) {
                }
            }, "node-host").apply { isDaemon = true; start() }
        }

        fun send(line: String) = ws.sendBinary(session!!.seal(line.toByteArray()))
        override fun close() = ws.close()
    }

    private fun readLine(s: Socket): String? {
        val b = ByteArrayOutputStream()
        while (true) {
            val x = s.getInputStream().read()
            if (x < 0) return null
            if (x == '\n'.code) return b.toString("UTF-8")
            b.write(x)
        }
    }

    private fun awaitSession(h: Host) {
        val end = System.currentTimeMillis() + 5_000
        while (h.session == null && System.currentTimeMillis() < end) Thread.sleep(10)
    }

    @Test fun aPhoneAndAComputerTalkBothWaysThroughTheRealRelay() {
        Host().use { host ->
            val phone = RelayConnector(pairing()).connect(3_000)
            try {
                phone.getOutputStream().write("{\"type\":\"hello\"}\n".toByteArray())
                assertEquals("{\"type\":\"hello\"}", host.lines.poll(5, TimeUnit.SECONDS))
                host.send("{\"type\":\"welcome\"}")
                assertEquals("{\"type\":\"welcome\"}", readLine(phone))
                // A larger line, several frames in a row, and both directions interleaved.
                val big = "{\"x\":\"" + "a".repeat(40_000) + "\"}"
                repeat(5) { phone.getOutputStream().write((big + "\n").toByteArray()) }
                repeat(5) { assertEquals(big, host.lines.poll(5, TimeUnit.SECONDS)) }
                repeat(5) { host.send(big) }
                repeat(5) { assertEquals(big, readLine(phone)) }
            } finally {
                phone.close()
            }
        }
    }

    @Test fun theLinkClientRunsThroughTheRealRelay() {
        Host().use { host ->
            val welcomed = java.util.concurrent.CountDownLatch(1)
            val listener = object : LinkListener { override fun onWelcome(desktopName: String, os: String) { welcomed.countDown() } }
            val payload = PairingPayload("192.0.2.1", 1, "ab".repeat(32), "tok_en-1234567890abcd", "PC", pairing())
            val client = LinkClient(payload, "Phone", listener, connector = RelayConnector(pairing()), caps = emptyList())
            client.start()
            try {
                assertTrue(host.lines.poll(10, TimeUnit.SECONDS)!!.contains("\"hello\""))
                host.send("""{"type":"welcome","v":1,"desktop":"Test PC","os":"linux"}""")
                assertTrue(welcomed.await(5, TimeUnit.SECONDS))
            } finally {
                client.stop()
            }
        }
    }

    @Test fun aWrongAccessKeyIsRefusedByTheRelay() {
        val c = RelayConnector(pairing(accessKey = RelayCrypto.base64UrlEncode(ByteArray(32) { 1 })))
        try { c.connect(3_000); fail() } catch (e: WsHandshakeException) { assertEquals(401, e.status) }
        assertEquals(RelayIssue.ACCESS_REFUSED, c.issue)
    }

    @Test fun aWrongPairingKeyCannotJoinARoomThatIsInUse() {
        Host().use {
            val other = RelayCrypto.PairingKey(ByteArray(32) { 77 })
            val c = RelayConnector(pairing(k = other), answerTimeoutMs = 3_000)
            try { c.connect(3_000); fail() } catch (_: IOException) {}
            assertEquals(RelayIssue.ROOM_TAKEN, c.issue)
        }
    }

    @Test fun aComputerThatIsNotThereIsReportedAfterTheWait() {
        val c = RelayConnector(pairing(), answerTimeoutMs = 600, resendMs = 200)
        try { c.connect(3_000); fail() } catch (_: IOException) {}
        assertEquals(RelayIssue.COMPUTER_AWAY, c.issue)
    }

    @Test fun aComputerThatJoinsLaterIsFoundWithoutRetrying() {
        // The phone is already waiting when the computer arrives: the relay's "online" hint (or the resent init) completes it.
        val result = LinkedBlockingQueue<Any>()
        Thread({ result.put(runCatching { RelayConnector(pairing(), answerTimeoutMs = 8_000, resendMs = 300).connect(3_000) }) }).apply { isDaemon = true; start() }
        Thread.sleep(500)
        Host().use { host ->
            val r = result.poll(8, TimeUnit.SECONDS) as Result<*>
            val socket = r.getOrThrow() as Socket
            socket.getOutputStream().write("{\"type\":\"ping\"}\n".toByteArray())
            assertEquals("{\"type\":\"ping\"}", host.lines.poll(5, TimeUnit.SECONDS))
            socket.close()
        }
    }

    @Test fun whenTheComputerGoesAwayTheStreamEnds() {
        val host = Host()
        val phone = RelayConnector(pairing()).connect(3_000)
        awaitSession(host)
        host.close()
        phone.soTimeout = 5_000
        assertEquals(null, readLine(phone))
        phone.close()
    }

    @Test fun aSecondPhoneReplacesTheFirstOne() {
        Host().use { host ->
            val first = RelayConnector(pairing()).connect(3_000)
            val second = RelayConnector(pairing()).connect(3_000)
            first.soTimeout = 5_000
            assertEquals("the first phone was replaced", null, readLine(first))
            second.getOutputStream().write("{\"type\":\"ping\"}\n".toByteArray())
            assertEquals("{\"type\":\"ping\"}", host.lines.poll(5, TimeUnit.SECONDS))
            second.close()
        }
    }
}
