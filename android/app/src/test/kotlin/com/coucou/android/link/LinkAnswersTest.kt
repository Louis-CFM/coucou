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

/** The client against a plain-socket pretend computer: a question is surfaced and answered only when `answers` was offered. */
class LinkAnswersTest {
    private val fp = "cd".repeat(32)
    private val server = ServerSocket(0)
    private val received = LinkedBlockingQueue<String>()
    private var welcomeCaps = """["answers"]"""
    private var sendQuestion = true
    private val pairing get() = PairingPayload("127.0.0.1", server.localPort, "ab".repeat(32), "T".repeat(20), "PC")

    private val questions = CopyOnWriteArrayList<QuestionRequest>()
    private val welcome = CountDownLatch(1)
    private val question = CountDownLatch(1)
    private val listener = object : LinkListener {
        override fun onWelcome(desktopName: String, os: String) { welcome.countDown() }
        override fun onQuestion(request: QuestionRequest) { questions.add(request); question.countDown() }
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
                        if (sendQuestion) {
                            send("""{"type":"question","pillId":"integration_claude","fingerprint":"$fp","createdAt":1,"questions":[{"question":"Which?","multiSelect":false,"options":[{"label":"A","description":""},{"label":"B","description":""}]}]}""")
                        }
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
        return c
    }

    @Test fun aQuestionIsSurfacedAndAnAnswerIsSentWhenAnswersWasOffered() {
        val c = start()
        assertTrue(question.await(5, TimeUnit.SECONDS))
        assertEquals("Which?", questions[0].questions[0].question)
        assertTrue(c.answer(fp, listOf(listOf("B"))))
        var sent: String? = null
        repeat(20) { if (sent == null) sent = received.poll(250, TimeUnit.MILLISECONDS)?.takeIf { it.contains("\"type\":\"answer\"") } }
        val o = org.json.JSONObject(sent!!)
        assertEquals("answer", o.getString("type"))
        assertEquals(fp, o.getString("fingerprint"))
        assertEquals("""[["B"]]""", o.getJSONArray("picks").toString())
    }

    @Test fun withoutTheOfferTheQuestionIsIgnoredAndNothingCanBeSent() {
        welcomeCaps = "[]"
        val c = start()
        assertFalse("a computer that did not offer answers: its question is not surfaced", question.await(700, TimeUnit.MILLISECONDS))
        assertFalse(c.answer(fp, listOf(listOf("A"))))
        assertTrue(received.none { it.contains("\"type\":\"answer\"") })
    }

    @Test fun anAppThatDidNotAskNeverSendsAnAnswer() {
        val c = start(caps = listOf("chat"))
        assertFalse(question.await(700, TimeUnit.MILLISECONDS))
        assertFalse(c.answer(fp, listOf(listOf("A"))))
    }

    @Test fun theHelloAsksForAnswers() {
        start()
        val hello = received.poll(2, TimeUnit.SECONDS)!!
        assertTrue(hello, hello.contains("\"answers\""))
    }
}
