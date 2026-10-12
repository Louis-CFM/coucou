package com.coucou.android.link

import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The client against a plain-socket pretend computer: a diff is asked for and delivered only when `diffs` was offered. */
class LinkDiffsTest {
    private val server = ServerSocket(0)
    private val received = LinkedBlockingQueue<String>()
    private var welcomeCaps = """["diffs"]"""
    private val pairing get() = PairingPayload("127.0.0.1", server.localPort, "ab".repeat(32), "T".repeat(20), "PC")

    private val parts = CopyOnWriteArrayList<ServerMsg.Diff>()
    private val welcome = CountDownLatch(1)
    private val gotPart = CountDownLatch(1)
    private val capsKnown = CountDownLatch(1)
    private val listener = object : LinkListener {
        override fun onWelcome(desktopName: String, os: String) { welcome.countDown() }
        override fun onCaps(caps: Set<String>) { capsKnown.countDown() }
        override fun onDiff(part: ServerMsg.Diff) { parts.add(part); gotPart.countDown() }
    }

    init {
        Thread {
            try {
                val s: Socket = server.accept()
                val r = BufferedReader(InputStreamReader(s.getInputStream()))
                val out = s.getOutputStream()
                fun send(line: String) { out.write((line + "\n").toByteArray()); out.flush() }
                while (true) {
                    val line = r.readLine() ?: break
                    received.add(line)
                    if (line.contains("\"type\":\"hello\"")) {
                        send("""{"type":"welcome","v":1,"desktop":"PC","os":"windows","caps":$welcomeCaps}""")
                        // sent whether or not it was asked for: a client must not surface what it did not ask for
                        send("""{"type":"diff","pillId":"integration_claude","fileId":7,"name":"app.ts","part":0,"parts":1,"lines":[["+","x"]]}""")
                    }
                }
            } catch (_: Exception) { }
        }.apply { isDaemon = true; start() }
    }

    private var client: LinkClient? = null

    @After fun stop() { client?.stop(); runCatching { server.close() } }

    private fun start(caps: List<String> = Protocol.CAPABILITIES): LinkClient {
        val c = LinkClient(pairing, "test", listener, connector = { Socket("127.0.0.1", server.localPort) }, backoffMs = longArrayOf(50), caps = caps)
        client = c
        c.start()
        assertTrue(welcome.await(5, TimeUnit.SECONDS))
        // The welcome is told before the offered capabilities are stored: wait for them too.
        assertTrue(capsKnown.await(5, TimeUnit.SECONDS))
        return c
    }

    @Test fun aDiffIsAskedForByFileAndDelivered() {
        val c = start()
        assertTrue(c.getDiff("integration_claude", 7))
        var sent: String? = null
        repeat(20) { if (sent == null) sent = received.poll(250, TimeUnit.MILLISECONDS)?.takeIf { it.contains("\"type\":\"getDiff\"") } }
        val o = org.json.JSONObject(sent!!)
        assertEquals("integration_claude", o.getString("pillId"))
        assertEquals(7L, o.getLong("fileId"))
        assertTrue(gotPart.await(5, TimeUnit.SECONDS))
        assertEquals("x", parts[0].lines[0].text)
    }

    @Test fun withoutTheOfferNothingCanBeAskedAndAnUnaskedDiffIsIgnored() {
        welcomeCaps = "[]"
        val c = start()
        assertFalse(gotPart.await(700, TimeUnit.MILLISECONDS))
        assertFalse(c.getDiff("integration_claude", 7))
        assertTrue(received.none { it.contains("getDiff") })
    }

    @Test fun anAppThatDidNotAskNeverAsks() {
        val c = start(caps = listOf("chat"))
        assertFalse(gotPart.await(700, TimeUnit.MILLISECONDS))
        assertFalse(c.getDiff("integration_claude", 7))
    }

    @Test fun theHelloAsksForDiffs() {
        start()
        val hello = received.poll(2, TimeUnit.SECONDS)!!
        assertTrue(hello, hello.contains("\"diffs\""))
    }
}
