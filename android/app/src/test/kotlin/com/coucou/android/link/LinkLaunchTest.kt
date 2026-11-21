package com.coucou.android.link

import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The client against a plain-socket pretend computer: a session can be asked for only when `launch` was offered, and what an older
 * computer (which knows nothing of it) or a computer that did not offer it sends about it is never surfaced.
 */
class LinkLaunchTest {
    private val server = ServerSocket(0)
    private val received = LinkedBlockingQueue<String>()
    private var welcomeCaps: String? = """["launch"]"""
    private val pairing get() = PairingPayload("127.0.0.1", server.localPort, "ab".repeat(32), "T".repeat(20), "PC")

    private val lists = CopyOnWriteArrayList<List<LaunchProject>>()
    private val results = CopyOnWriteArrayList<Triple<String, Boolean, String>>()
    private val welcome = CountDownLatch(1)
    private val capsKnown = CountDownLatch(1)
    private val gotList = CountDownLatch(1)
    private val gotResult = CountDownLatch(1)
    private val listener = object : LinkListener {
        override fun onWelcome(desktopName: String, os: String) { welcome.countDown() }
        override fun onCaps(caps: Set<String>) { capsKnown.countDown() }
        override fun onProjects(projects: List<LaunchProject>) { lists.add(projects); gotList.countDown() }
        override fun onLaunchResult(id: String, ok: Boolean, reason: String) { results.add(Triple(id, ok, reason)); gotResult.countDown() }
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
                        val caps = welcomeCaps?.let { ""","caps":$it""" } ?: ""
                        send("""{"type":"welcome","v":1,"desktop":"PC","os":"windows"$caps}""")
                        // Sent whether or not it was offered: a client must not surface what was not negotiated.
                        send("""{"type":"projects","projects":[{"id":"3f9a00112233aabb","name":"coucou"}]}""")
                    }
                    if (line.contains("\"type\":\"launch\"")) {
                        val o = JSONObject(line)
                        val ok = o.getString("project") == "3f9a00112233aabb"
                        send(JSONObject().put("type", "launchResult").put("id", o.getString("id")).put("ok", ok).apply { if (!ok) put("reason", "unknown_project") }.toString())
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
        assertTrue(capsKnown.await(5, TimeUnit.SECONDS))
        return c
    }

    private fun sentLaunch(): JSONObject? {
        repeat(20) { received.poll(250, TimeUnit.MILLISECONDS)?.takeIf { it.contains("\"type\":\"launch\"") }?.let { return JSONObject(it) } }
        return null
    }

    @Test fun theListArrivesAndASessionIsAskedForByProjectIdAndAnswered() {
        val c = start()
        assertTrue(gotList.await(5, TimeUnit.SECONDS))
        assertEquals(listOf(LaunchProject("3f9a00112233aabb", "coucou")), lists[0])
        assertTrue(c.launch("a1", "3f9a00112233aabb", "fix the tests"))
        val o = sentLaunch()!!
        assertEquals(setOf("type", "id", "project", "prompt"), o.keySet())
        assertEquals("fix the tests", o.getString("prompt"))
        assertTrue(gotResult.await(5, TimeUnit.SECONDS))
        assertEquals(Triple("a1", true, ""), results[0])
    }

    @Test fun aRefusalComesBackWithItsReason() {
        val c = start()
        assertTrue(c.launch("b2", "not-in-the-list", "do it"))
        assertTrue(gotResult.await(5, TimeUnit.SECONDS))
        assertEquals(Triple("b2", false, "unknown_project"), results[0])
    }

    @Test fun aComputerThatDoesNotKnowItOffersNothingAndNothingIsSentToIt() {
        // An older computer: no caps at all in its welcome.
        welcomeCaps = null
        val c = start()
        assertFalse("its stray projects line is not surfaced", gotList.await(700, TimeUnit.MILLISECONDS))
        assertFalse(c.launch("a1", "3f9a00112233aabb", "do it"))
        assertTrue(received.none { it.contains("\"type\":\"launch\"") })
    }

    @Test fun aComputerWithTheSwitchOffIsTheSame() {
        welcomeCaps = """["details","usage"]"""
        val c = start()
        assertFalse(gotList.await(700, TimeUnit.MILLISECONDS))
        assertFalse(c.launch("a1", "3f9a00112233aabb", "do it"))
        assertTrue(received.none { it.contains("\"type\":\"launch\"") })
    }

    @Test fun anAppThatDidNotAskNeverAsks() {
        val c = start(caps = listOf("chat"))
        assertFalse(gotList.await(700, TimeUnit.MILLISECONDS))
        assertFalse(c.launch("a1", "3f9a00112233aabb", "do it"))
    }
}
