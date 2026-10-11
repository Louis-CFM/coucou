package com.coucou.android.link

import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.ServerSocket
import java.net.Socket
import java.security.KeyStore
import java.security.MessageDigest
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLServerSocket
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** A pretend desktop: real TLS with the test certificate, speaking the v1 protocol. */
internal class FakeDesktop(tls: Boolean) : AutoCloseable {
    val server: ServerSocket
    val certSha256: String
    val received = LinkedBlockingQueue<String>()
    @Volatile var peer: Socket? = null
    val peerClosed = CountDownLatch(1)
    @Volatile var welcomeVersion = Protocol.VERSION
    @Volatile var expectedToken = "T".repeat(20)
    /** False: the desktop reads everything and answers nothing, like a connection that died quietly. */
    @Volatile var answerPings = true
    /** Extra JSON in the welcome, such as `,"caps":["chat"]`. */
    @Volatile var welcomeExtra = ""
    private val fp = "f".repeat(64)

    init {
        val ks = KeyStore.getInstance("PKCS12")
        javaClass.getResourceAsStream("/test-desktop.p12").use { ks.load(it, "changeit".toCharArray()) }
        certSha256 = MessageDigest.getInstance("SHA-256")
            .digest(ks.getCertificate("desktop").encoded).joinToString("") { "%02x".format(it) }
        server = if (tls) {
            val kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply { init(ks, "changeit".toCharArray()) }
            val ctx = SSLContext.getInstance("TLS").apply { init(kmf.keyManagers, null, null) }
            (ctx.serverSocketFactory.createServerSocket(0) as SSLServerSocket)
        } else ServerSocket(0)
        Thread {
            try {
                while (true) serve(server.accept())
            } catch (_: Exception) { }
        }.apply { isDaemon = true; start() }
    }

    val port get() = server.localPort

    private fun serve(s: Socket) {
        peer = s
        Thread {
            try {
                val r = BufferedReader(InputStreamReader(s.getInputStream()))
                val out = s.getOutputStream()
                fun send(line: String) { out.write((line + "\n").toByteArray()); out.flush() }
                while (true) {
                    val line = r.readLine() ?: break
                    received.add(line)
                    if (line.contains("\"type\":\"hello\"")) {
                        if (!line.contains("\"token\":\"$expectedToken\"")) { send("""{"type":"error","code":"auth","message":"bad token"}"""); break }
                        send("""{"type":"welcome","v":$welcomeVersion,"desktop":"Test PC","os":"windows"$welcomeExtra}""")
                        send("""{"type":"sessions","sessions":[{"pillId":"agent_codex","state":"working"}]}""")
                    }
                    if (answerPings && line.contains("\"type\":\"ping\"")) send("""{"type":"pong"}""")
                }
            } catch (_: Exception) { } finally { runCatching { s.close() }; peerClosed.countDown() }
        }.apply { isDaemon = true; start() }
    }

    fun push(line: String) { peer!!.getOutputStream().apply { write((line + "\n").toByteArray()); flush() } }
    fun approvalJson(created: Long) =
        """{"type":"approval","pillId":"agent_codex","fingerprint":"$fp","tool":"Bash","command":"ls","createdAt":$created}"""
    val approvalFingerprint get() = fp
    fun dropConnection() { peer?.close() }
    override fun close() { runCatching { peer?.close() }; runCatching { server.close() } }
}

private class Recorder : LinkListener {
    val states = CopyOnWriteArrayList<LinkState>()
    val sessions = LinkedBlockingQueue<List<SessionInfo>>()
    val approvals = LinkedBlockingQueue<ApprovalRequest>()
    val resolved = LinkedBlockingQueue<String>()
    val errors = LinkedBlockingQueue<String>()
    val lost = LinkedBlockingQueue<LostReason>()
    val connected = CountDownLatch(1)
    @Volatile var desktop: String? = null
    override fun onState(state: LinkState) { states.add(state) }
    override fun onWelcome(desktopName: String, os: String) { desktop = desktopName; connected.countDown() }
    override fun onSessions(sessions: List<SessionInfo>) { this.sessions.add(sessions) }
    override fun onApproval(request: ApprovalRequest) { approvals.add(request) }
    override fun onApprovalResolved(fingerprint: String) { resolved.add(fingerprint) }
    override fun onError(code: String, message: String) { errors.add(code) }
    override fun onLinkLost(reason: LostReason) { lost.add(reason) }
    val caps = LinkedBlockingQueue<Set<String>>()
    val chatEvents = LinkedBlockingQueue<String>()
    override fun onCaps(caps: Set<String>) { this.caps.add(caps) }
    override fun onChatModels(models: List<ChatModel>) { chatEvents.add("models:" + models.joinToString(",") { it.id }) }
    override fun onChatDelta(id: String, text: String) { chatEvents.add("delta:$id:$text") }
    override fun onChatDone(id: String, text: String?) { chatEvents.add("done:$id:${text ?: "-"}") }
    override fun onChatError(id: String, reason: String, message: String) { chatEvents.add("error:$id:$reason") }
}

class LinkClientTest {
    private val closeables = mutableListOf<AutoCloseable>()
    private var now = System.currentTimeMillis()
    private val token = "T".repeat(20)

    @After fun cleanup() = closeables.forEach { runCatching { it.close() } }

    private fun <T : AutoCloseable> T.track(): T { closeables.add(this); return this }

    private fun payload(d: FakeDesktop, fp: String = d.certSha256) = PairingPayload("127.0.0.1", d.port, fp, token, "Test PC")

    private fun client(d: FakeDesktop, rec: Recorder, p: PairingPayload = payload(d), plain: Boolean = false, backoff: LongArray = longArrayOf(50), readTimeoutMs: Int = 2_000): LinkClient {
        val connector = if (plain) Connector { ms -> Socket().apply { connect(java.net.InetSocketAddress(p.host, p.port), ms) } } else PinnedTls.connector(p)
        return LinkClient(p, "Pixel", rec, connector, clockMs = { now }, readTimeoutMs = readTimeoutMs, pingEveryMs = 100, backoffMs = backoff, pongWaitMs = 300)
            .also { closeables.add(AutoCloseable { it.stop() }) }
    }

    @Test fun connectsOverPinnedTlsAndReceivesSessions() {
        val d = FakeDesktop(tls = true).track()
        val rec = Recorder()
        client(d, rec).start()
        assertTrue("never connected", rec.connected.await(5, TimeUnit.SECONDS))
        assertEquals("Test PC", rec.desktop)
        val s = rec.sessions.poll(5, TimeUnit.SECONDS)
        assertEquals("agent_codex", s!![0].pillId)
        assertTrue(rec.states.contains(LinkState.CONNECTED))
        assertTrue(d.received.poll(2, TimeUnit.SECONDS)!!.contains("\"device\":\"Pixel\""))
    }

    @Test fun refusesADesktopWithAnotherCertificate() {
        val d = FakeDesktop(tls = true).track()
        val rec = Recorder()
        client(d, rec, payload(d, fp = "00".repeat(32))).start()
        assertFalse("connected to an unpinned desktop", rec.connected.await(1500, TimeUnit.MILLISECONDS))
        assertNull(d.received.poll(200, TimeUnit.MILLISECONDS))
        assertFalse(rec.states.contains(LinkState.CONNECTED))
    }

    @Test fun neverSendsTheTokenInTheClear() {
        // A plain-text server must not be able to complete the pinned-TLS connector's handshake.
        val d = FakeDesktop(tls = false).track()
        val rec = Recorder()
        client(d, rec, payload(d)).start()
        assertFalse(rec.connected.await(1500, TimeUnit.MILLISECONDS))
        assertTrue("token leaked: ${d.received.toList()}", d.received.none { it.contains("token") })
    }

    @Test fun approvalCanBeAllowedOnceAndTheDesktopReceivesIt() {
        val d = FakeDesktop(tls = true).track()
        val rec = Recorder()
        val c = client(d, rec)
        c.start()
        assertTrue(rec.connected.await(5, TimeUnit.SECONDS))
        d.push(d.approvalJson(now))
        val req = rec.approvals.poll(5, TimeUnit.SECONDS)
        assertNotNull(req)
        assertTrue(c.decide(req!!.fingerprint, allow = true))
        assertFalse("second decision for the same request", c.decide(req.fingerprint, allow = false))
        val decision = generateSequence { d.received.poll(3, TimeUnit.SECONDS) }.first { it.contains("decision") }
        assertTrue(decision.contains("\"decision\":\"allow\"") && decision.contains(req.fingerprint))
    }

    @Test fun cannotDecideAnUnknownRequest() {
        val d = FakeDesktop(tls = true).track()
        val rec = Recorder()
        val c = client(d, rec)
        c.start()
        assertTrue(rec.connected.await(5, TimeUnit.SECONDS))
        assertFalse(c.decide("e".repeat(64), allow = true))
    }

    @Test fun expiredApprovalIsRefused() {
        val d = FakeDesktop(tls = true).track()
        val rec = Recorder()
        val c = client(d, rec)
        c.start()
        assertTrue(rec.connected.await(5, TimeUnit.SECONDS))
        d.push(d.approvalJson(now))
        val req = rec.approvals.poll(5, TimeUnit.SECONDS)!!
        now += Protocol.APPROVAL_TTL_MS
        assertFalse(c.decide(req.fingerprint, allow = true))
        assertTrue("no decision must reach the desktop", d.received.none { it.contains("\"type\":\"decision\"") })
    }

    @Test fun desktopResolvingTheApprovalRemovesIt() {
        val d = FakeDesktop(tls = true).track()
        val rec = Recorder()
        val c = client(d, rec)
        c.start()
        assertTrue(rec.connected.await(5, TimeUnit.SECONDS))
        d.push(d.approvalJson(now))
        val req = rec.approvals.poll(5, TimeUnit.SECONDS)!!
        d.push("""{"type":"approvalResolved","fingerprint":"${req.fingerprint}"}""")
        assertEquals(req.fingerprint, rec.resolved.poll(5, TimeUnit.SECONDS))
        assertFalse(c.decide(req.fingerprint, allow = true))
    }

    @Test fun reconnectsAfterTheLinkDrops() {
        val d = FakeDesktop(tls = true).track()
        val rec = Recorder()
        client(d, rec).start()
        assertTrue(rec.connected.await(5, TimeUnit.SECONDS))
        rec.sessions.poll(5, TimeUnit.SECONDS)
        d.dropConnection()
        val again = rec.sessions.poll(8, TimeUnit.SECONDS)
        assertNotNull("did not reconnect", again)
        assertTrue(rec.states.count { it == LinkState.CONNECTED } >= 2)
    }

    @Test fun wrongTokenGetsAnAuthErrorAndTheClientStopsRetrying() {
        val d = FakeDesktop(tls = true).track().also { it.expectedToken = "other-token-123456789" }
        val rec = Recorder()
        client(d, rec).start()
        assertEquals("auth", rec.errors.poll(5, TimeUnit.SECONDS))
        assertFalse(rec.connected.await(300, TimeUnit.MILLISECONDS))
        Thread.sleep(600) // the backoff is 50 ms here: a retrying client would have said hello again by now
        assertEquals(1, d.received.count { it.contains("\"type\":\"hello\"") })
        assertEquals(LinkState.DISCONNECTED, rec.states.last())
    }

    @Test fun versionMismatchIsReportedAndNotRetried() {
        val d = FakeDesktop(tls = true).track().also { it.welcomeVersion = 99 }
        val rec = Recorder()
        client(d, rec).start()
        assertEquals("version", rec.errors.poll(5, TimeUnit.SECONDS))
        assertFalse(rec.states.contains(LinkState.CONNECTED))
        Thread.sleep(600)
        assertEquals(1, d.received.count { it.contains("\"type\":\"hello\"") })
    }

    @Test fun sendsKeepAlivePings() {
        val d = FakeDesktop(tls = true).track()
        val rec = Recorder()
        client(d, rec).start()
        assertTrue(rec.connected.await(5, TimeUnit.SECONDS))
        val ping = generateSequence { d.received.poll(3, TimeUnit.SECONDS) }.take(10).any { it.contains("\"type\":\"ping\"") }
        assertTrue(ping)
    }

    @Test fun decisionsAndStopNeverTouchTheNetworkOnTheCallersThread() {
        // Android throws NetworkOnMainThreadException if the UI thread writes to a socket.
        val d = FakeDesktop(tls = false).track()
        val rec = Recorder()
        val writers = CopyOnWriteArrayList<Pair<String, Thread>>()
        val p = payload(d)
        val connector = Connector { ms ->
            object : Socket() {
                override fun getOutputStream(): java.io.OutputStream {
                    val real = super.getOutputStream()
                    return object : java.io.OutputStream() {
                        override fun write(b: Int) = real.write(b)
                        override fun write(b: ByteArray, off: Int, len: Int) {
                            writers.add(String(b, off, len) to Thread.currentThread())
                            real.write(b, off, len)
                        }
                        override fun flush() = real.flush()
                    }
                }
            }.apply { connect(java.net.InetSocketAddress(p.host, p.port), ms) }
        }
        val c = LinkClient(p, "Pixel", rec, connector, clockMs = { now }, readTimeoutMs = 2_000, pingEveryMs = 60_000)
        closeables.add(AutoCloseable { c.stop() })
        c.start()
        assertTrue(rec.connected.await(5, TimeUnit.SECONDS))
        d.push(d.approvalJson(now))
        val req = rec.approvals.poll(5, TimeUnit.SECONDS)!!
        val caller = Thread.currentThread()
        assertTrue(c.decide(req.fingerprint, allow = false))
        c.stop()
        assertTrue(generateSequence { d.received.poll(3, TimeUnit.SECONDS) }.take(6).any { it.contains("\"decision\":\"deny\"") })
        assertTrue("nothing was written", writers.isNotEmpty())
        assertTrue("a write happened on the caller's thread", writers.none { it.second === caller && it.first.contains("decision") })
    }

    @Test fun stopEndsTheLinkAndStaysStopped() {
        val d = FakeDesktop(tls = true).track()
        val rec = Recorder()
        val c = client(d, rec)
        c.start()
        assertTrue(rec.connected.await(5, TimeUnit.SECONDS))
        c.stop() // "bye" is best effort; the desktop must at least see the connection end
        assertTrue("desktop never saw the link close", d.peerClosed.await(5, TimeUnit.SECONDS))
        assertFalse(c.decide("a".repeat(64), true))
        val deadline = System.currentTimeMillis() + 3000
        while (rec.states.lastOrNull() != LinkState.DISCONNECTED && System.currentTimeMillis() < deadline) Thread.sleep(20)
        assertEquals(LinkState.DISCONNECTED, rec.states.last())
    }

    // ── chat ────────────────────────────────────────────────────────────────

    @Test fun theHelloAsksForChatUnlessTheAppAsksForNothing() {
        val d = FakeDesktop(tls = true).track()
        val rec = Recorder()
        client(d, rec).start()
        assertTrue(rec.connected.await(5, TimeUnit.SECONDS))
        assertTrue(d.received.poll(2, TimeUnit.SECONDS)!!.contains("\"caps\":[\"chat\",\"details\",\"answers\",\"prefs\",\"diffs\",\"usage\",\"services\",\"relay\"]"))

        val old = FakeDesktop(tls = true).track()
        val rec2 = Recorder()
        val p = payload(old)
        LinkClient(p, "Pixel", rec2, PinnedTls.connector(p), caps = emptyList(), readTimeoutMs = 2_000)
            .also { closeables.add(AutoCloseable { it.stop() }) }.start()
        assertTrue(rec2.connected.await(5, TimeUnit.SECONDS))
        val hello = old.received.poll(2, TimeUnit.SECONDS)!!
        assertFalse("an app with no optional features sends the plain v1 hello: $hello", hello.contains("caps"))
    }

    @Test fun aWelcomeWithoutCapsOffersNoChatAndTheModelsAreNotAsked() {
        val d = FakeDesktop(tls = true).track()
        val rec = Recorder()
        client(d, rec).start()
        assertTrue(rec.connected.await(5, TimeUnit.SECONDS))
        assertEquals(emptySet<String>(), rec.caps.poll(5, TimeUnit.SECONDS))
        Thread.sleep(300)
        assertTrue(d.received.none { it.contains("chatModels") })
    }

    @Test fun whenChatIsOfferedTheModelsAreAskedForAtOnce() {
        val d = FakeDesktop(tls = true).track().also { it.welcomeExtra = ""","caps":["chat"]""" }
        val rec = Recorder()
        client(d, rec).start()
        assertTrue(rec.connected.await(5, TimeUnit.SECONDS))
        assertEquals(setOf("chat"), rec.caps.poll(5, TimeUnit.SECONDS))
        val asked = generateSequence { d.received.poll(3, TimeUnit.SECONDS) }.take(6).firstOrNull { it.contains("chatModels") }
        assertNotNull("the models were never asked for", asked)
    }

    @Test fun chatMessagesReachTheListener() {
        val d = FakeDesktop(tls = true).track()
        val rec = Recorder()
        client(d, rec).start()
        assertTrue(rec.connected.await(5, TimeUnit.SECONDS))
        d.push("""{"type":"chatModels","models":[{"id":"openai/gpt","provider":"openai","label":"GPT"}]}""")
        d.push("""{"type":"chatDelta","id":"c1","text":"Hel"}""")
        d.push("""{"type":"chatDelta","id":"c1","text":"lo"}""")
        d.push("""{"type":"chatDone","id":"c1"}""")
        d.push("""{"type":"chatError","id":"c2","reason":"rate","message":"x"}""")
        d.push("""{"type":"chatDelta","id":"bad id","text":"ignored"}""")
        d.push("""{"type":"ping"}""") // an unknown type in the middle changes nothing
        val got = (1..5).map { rec.chatEvents.poll(5, TimeUnit.SECONDS) }
        assertEquals(listOf("models:openai/gpt", "delta:c1:Hel", "delta:c1:lo", "done:c1:-", "error:c2:rate"), got)
        assertNull(rec.chatEvents.poll(300, TimeUnit.MILLISECONDS))
    }

    @Test fun chatSendIsWrittenOffTheCallersThreadAndOnlyWhileConnected() {
        val d = FakeDesktop(tls = true).track()
        val rec = Recorder()
        val c = client(d, rec)
        assertFalse("not connected yet", c.chatSend("c0", "openai/gpt", "early"))
        c.start()
        assertTrue(rec.connected.await(5, TimeUnit.SECONDS))
        assertTrue(c.chatSend("c1", "openai/gpt", "hello \"there\""))
        c.chatCancel("c1")
        c.chatReset()
        c.chatModels()
        val lines = generateSequence { d.received.poll(3, TimeUnit.SECONDS) }.take(12).toList()
        val chat = lines.filter { it.contains("\"type\":\"chat") }
        assertEquals(
            listOf("chatSend", "chatCancel", "chatReset", "chatModels"),
            chat.map { org.json.JSONObject(it).getString("type") },
        )
        assertEquals("hello \"there\"", org.json.JSONObject(chat[0]).getString("text"))
        assertTrue(chat.none { it.contains("early") })
    }

    @Test fun theDemoOffersNoChat() {
        val demo = DemoLink(object : LinkListener {}, autoRun = false)
        assertFalse(demo.chatSend("c1", "a/b", "hi"))
    }

    // ── Keeping the link alive while the phone sleeps ──

    @Test fun aLivenessCheckDropsAConnectionThatStoppedAnsweringAndReconnects() {
        val d = FakeDesktop(tls = false).track()
        val rec = Recorder()
        // A read timeout of 30 s: only the liveness check can notice the silence within this test.
        client(d, rec, plain = true, backoff = longArrayOf(30), readTimeoutMs = 30_000).also { it.start() }.let { c ->
            assertTrue(rec.connected.await(5, TimeUnit.SECONDS))
            d.answerPings = false
            // A pong already on its way would count as "heard from it since the question": let the in-flight ones land first.
            Thread.sleep(500)
            now += 10_000 // the test's clock only moves when told to
            c.checkNow()
            assertEquals(LostReason.SILENT, rec.lost.poll(10, TimeUnit.SECONDS))
            d.answerPings = true
            // And it came back by itself with a new hello.
            val hellos = generateSequence { d.received.poll(3, TimeUnit.SECONDS) }.take(40).count { it.contains("\"type\":\"hello\"") }
            assertTrue("a second hello after the drop", hellos >= 2)
        }
    }

    @Test fun aLivenessCheckLeavesAHealthyConnectionAlone() {
        val d = FakeDesktop(tls = false).track()
        val rec = Recorder()
        val c = client(d, rec, plain = true)
        c.start()
        assertTrue(rec.connected.await(5, TimeUnit.SECONDS))
        repeat(3) { now += 10_000; c.checkNow(); Thread.sleep(150) }
        Thread.sleep(600)
        assertNull("no loss", rec.lost.poll())
        assertEquals(LinkState.CONNECTED, rec.states.last())
    }

    @Test fun aLivenessCheckWhileDisconnectedReconnectsAtOnceInsteadOfWaitingOutTheBackoff() {
        val d = FakeDesktop(tls = false).track()
        val rec = Recorder()
        val c = client(d, rec, plain = true, backoff = longArrayOf(60_000))
        c.start()
        assertTrue(rec.connected.await(5, TimeUnit.SECONDS))
        d.dropConnection()
        assertEquals(LostReason.CLOSED, rec.lost.poll(3, TimeUnit.SECONDS))
        Thread.sleep(200) // now it waits 60 s
        val before = d.received.count { it.contains("\"type\":\"hello\"") }
        c.checkNow()
        val deadline = System.currentTimeMillis() + 3_000
        var after = before
        while (after <= before && System.currentTimeMillis() < deadline) { Thread.sleep(50); after = d.received.count { it.contains("\"type\":\"hello\"") } }
        assertTrue("reconnected without waiting", after > before)
    }

    @Test fun aSilentConnectionIsReportedAsSilentAndAClosedOneAsClosed() {
        val d = FakeDesktop(tls = false).track()
        val rec = Recorder()
        client(d, rec, plain = true, backoff = longArrayOf(30)).start()
        assertTrue(rec.connected.await(5, TimeUnit.SECONDS))
        d.answerPings = false // the 2 s read timeout is what notices this one
        assertEquals(LostReason.SILENT, rec.lost.poll(5, TimeUnit.SECONDS))
    }

    @Test fun nothingIsReportedWhenTheUserStopsTheLink() {
        val d = FakeDesktop(tls = false).track()
        val rec = Recorder()
        val c = client(d, rec, plain = true)
        c.start()
        assertTrue(rec.connected.await(5, TimeUnit.SECONDS))
        c.stop()
        Thread.sleep(400)
        assertNull(rec.lost.poll())
    }
}
