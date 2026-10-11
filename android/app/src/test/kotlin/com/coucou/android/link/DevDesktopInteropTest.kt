package com.coucou.android.link

import com.coucou.android.ReferenceFiles
import java.io.BufferedReader
import java.io.InputStreamReader
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * The real [LinkClient] against android/tools/dev-desktop.mjs, a separate implementation of the
 * protocol (Node's TLS stack, its own certificate). Skipped when node or openssl is missing.
 */
class DevDesktopInteropTest {
    private var proc: Process? = null
    private val lines = LinkedBlockingQueue<String>()

    @After fun cleanup() { proc?.destroyForcibly() }

    // `openssl --version` is not a command (it is `openssl version`): the old check made these tests skip everywhere.
    private fun have(cmd: String, versionArg: String = "--version") = try {
        ProcessBuilder(cmd, versionArg).redirectErrorStream(true).start().also { it.inputStream.readBytes() }.waitFor() == 0
    } catch (_: Exception) { false }

    private fun startDesktop(vararg extra: String): JSONObject {
        assumeTrue("node not available", have("node"))
        assumeTrue("openssl not available", have("openssl", "version"))
        val script = ReferenceFiles.file("android/tools/dev-desktop.mjs").absolutePath
        proc = ProcessBuilder(listOf("node", script, "--host", "127.0.0.1", "--port", "0", "--quiet", "--step", "300") + extra)
            .redirectErrorStream(true).start()
        Thread {
            BufferedReader(InputStreamReader(proc!!.inputStream)).forEachLine { lines.add(it) }
        }.apply { isDaemon = true; start() }
        val first = lines.poll(20, TimeUnit.SECONDS)
        assertNotNull("dev desktop did not start", first)
        return JSONObject(first!!)
    }

    private class Rec : LinkListener {
        val welcome = LinkedBlockingQueue<String>()
        val sessions = LinkedBlockingQueue<List<SessionInfo>>()
        val approvals = LinkedBlockingQueue<ApprovalRequest>()
        val resolved = LinkedBlockingQueue<String>()
        val errors = LinkedBlockingQueue<String>()
        override fun onWelcome(desktopName: String, os: String) { welcome.add(desktopName) }
        override fun onSessions(sessions: List<SessionInfo>) { this.sessions.add(sessions) }
        override fun onApproval(request: ApprovalRequest) { approvals.add(request) }
        override fun onApprovalResolved(fingerprint: String) { resolved.add(fingerprint) }
        override fun onError(code: String, message: String) { errors.add(code) }
        val serviceCards = LinkedBlockingQueue<List<ServiceCard>>()
        override fun onServices(cards: List<ServiceCard>) { serviceCards.add(cards) }
        val usages = LinkedBlockingQueue<UsageSnapshot>()
        override fun onUsage(usage: UsageSnapshot) { usages.add(usage) }
        val diffParts = LinkedBlockingQueue<ServerMsg.Diff>()
        override fun onDiff(part: ServerMsg.Diff) { diffParts.add(part) }
        val questions = LinkedBlockingQueue<QuestionRequest>()
        override fun onQuestion(request: QuestionRequest) { questions.add(request) }
        val caps = LinkedBlockingQueue<Set<String>>()
        val chat = LinkedBlockingQueue<String>()
        override fun onCaps(caps: Set<String>) { this.caps.add(caps) }
        override fun onChatModels(models: List<ChatModel>) { chat.add("models:" + models.joinToString(",") { it.id }) }
        override fun onChatDelta(id: String, text: String) { chat.add("delta:$id:$text") }
        override fun onChatDone(id: String, text: String?) { chat.add("done:$id:${text ?: "-"}") }
        override fun onChatError(id: String, reason: String, message: String) { chat.add("error:$id:$reason") }

        /** Everything of one answer until its end. */
        fun answer(id: String, seconds: Long = 10): Pair<String, String> {
            val text = StringBuilder()
            val deadline = System.currentTimeMillis() + seconds * 1000
            while (System.currentTimeMillis() < deadline) {
                val e = chat.poll(200, TimeUnit.MILLISECONDS) ?: continue
                when {
                    e.startsWith("delta:$id:") -> text.append(e.removePrefix("delta:$id:"))
                    e.startsWith("done:$id:") -> return text.toString() to ("done:" + e.removePrefix("done:$id:"))
                    e.startsWith("error:$id:") -> return text.toString() to e
                }
            }
            error("no end of answer for $id")
        }
    }

    private fun chatClient(info: JSONObject, rec: Rec, caps: List<String> = Protocol.CAPABILITIES): LinkClient =
        LinkClient(PairingPayload.parse(info.getString("link"))!!, "Interop Pixel", rec, readTimeoutMs = 5_000, caps = caps)

    @Test fun pairsReceivesSessionsAndApprovalAndDecides() {
        val info = startDesktop("--once")
        val pairing = PairingPayload.parse(info.getString("link"))
        assertNotNull("pairing link not parsed: ${info.getString("link")}", pairing)
        val rec = Rec()
        val client = LinkClient(pairing!!, "Interop Pixel", rec, readTimeoutMs = 5_000)
        try {
            client.start()
            assertNotNull(rec.welcome.poll(10, TimeUnit.SECONDS))
            assertTrue(rec.sessions.poll(10, TimeUnit.SECONDS)!!.isNotEmpty())
            val req = rec.approvals.poll(10, TimeUnit.SECONDS)
            assertNotNull("no approval request arrived", req)
            // The fingerprint must be the one the Mac-compatible derivation yields for these fields.
            assertTrue(Wire.isFingerprint(req!!.fingerprint))
            assertTrue(client.decide(req.fingerprint, allow = true))
            assertEquals(req.fingerprint, rec.resolved.poll(10, TimeUnit.SECONDS))
            val deadline = System.currentTimeMillis() + 10_000
            var sawDecision = false
            while (!sawDecision && System.currentTimeMillis() < deadline) {
                val l = lines.poll(1, TimeUnit.SECONDS) ?: continue
                if (l == "DECISION allow ${req.fingerprint}") sawDecision = true
            }
            assertTrue("desktop never logged the decision", sawDecision)
        } finally {
            client.stop()
        }
    }

    @Test fun wrongTokenIsRejectedByTheNodeDesktop() {
        val info = startDesktop()
        val good = PairingPayload.parse(info.getString("link"))!!
        val rec = Rec()
        val client = LinkClient(good.copy(token = "x".repeat(24)), "Interop Pixel", rec, readTimeoutMs = 5_000)
        try {
            client.start()
            assertEquals("auth", rec.errors.poll(10, TimeUnit.SECONDS))
            assertTrue(rec.welcome.isEmpty())
        } finally {
            client.stop()
        }
    }

    // ── answering a question, against the fake question of the Node desktop ─────────

    @Test fun aQuestionIsAnsweredAndRemovedOnTheNodeDesktop() {
        val info = startDesktop("--answers", "--once")
        val rec = Rec()
        val client = chatClient(info, rec)
        try {
            client.start()
            assertEquals(setOf("answers"), rec.caps.poll(10, TimeUnit.SECONDS))
            val q = rec.questions.poll(20, TimeUnit.SECONDS)
            assertNotNull("no question arrived", q)
            assertEquals(2, q!!.questions.size)
            assertEquals(true, q.questions[1].multiSelect)
            // Refused by the desktop: a label it never offered, then two picks for a single choice.
            assertTrue(client.answer(q.fingerprint, listOf(listOf("nope"), listOf("Lint"))))
            assertTrue(client.answer(q.fingerprint, listOf(listOf("main", "develop"), listOf("Lint"))))
            assertNull(rec.resolved.poll(1, TimeUnit.SECONDS))
            assertTrue(client.answer(q.fingerprint, listOf(listOf("develop"), listOf("Lint", "Build"))))
            assertEquals(q.fingerprint, rec.resolved.poll(10, TimeUnit.SECONDS))
            val deadline = System.currentTimeMillis() + 10_000
            val seen = mutableListOf<String>()
            while (System.currentTimeMillis() < deadline && seen.none { it.startsWith("ANSWER accepted") }) {
                lines.poll(1, TimeUnit.SECONDS)?.let { seen.add(it) }
            }
            assertEquals(2, seen.count { it.startsWith("ANSWER refused") })
            assertTrue(seen.any { it.startsWith("ANSWER accepted") })
            assertTrue("the picked labels must not be logged", seen.none { it.contains("Build") || it.contains("develop") })
        } finally {
            client.stop()
        }
    }

    @Test fun theServiceCardsComeWithTheSwitchOnTheNodeDesktop() {
        val info = startDesktop("--services")
        val rec = Rec()
        val client = chatClient(info, rec)
        try {
            client.start()
            assertEquals(setOf("services"), rec.caps.poll(10, TimeUnit.SECONDS))
            val cards = rec.serviceCards.poll(10, TimeUnit.SECONDS)!!
            assertEquals(listOf("integration_stripe", "integration_notion"), cards.map { it.id })
            assertEquals("Roadmap", cards[1].items[0].label)
        } finally {
            client.stop()
        }
    }

    @Test fun theUsageComesWithTheSwitchOnTheNodeDesktop() {
        val info = startDesktop("--usage")
        val rec = Rec()
        val client = chatClient(info, rec)
        try {
            client.start()
            assertEquals(setOf("usage"), rec.caps.poll(10, TimeUnit.SECONDS))
            val u = rec.usages.poll(10, TimeUnit.SECONDS)!!
            assertEquals(21, u.claude!!.sevenDay!!.pct)
            assertEquals(2, u.codex!!.resetCredits)
        } finally {
            client.stop()
        }
    }

    @Test fun filesAreListedAndTheirLinesComeInPartsOnTheNodeDesktop() {
        val info = startDesktop("--diffs")
        val rec = Rec()
        val client = chatClient(info, rec)
        try {
            client.start()
            assertEquals(setOf("diffs"), rec.caps.poll(10, TimeUnit.SECONDS))
            val files = generateSequence { rec.sessions.poll(10, TimeUnit.SECONDS) }.take(5).first { l -> l.any { it.files.isNotEmpty() } }
                .first { it.files.isNotEmpty() }.files
            assertEquals(listOf("app.ts", "long-file.ts", "generated.json"), files.map { it.name })
            assertTrue(files[2].tooLarge)

            assertTrue(client.getDiff("integration_claude", 1))
            val small = rec.diffParts.poll(10, TimeUnit.SECONDS)!!
            assertEquals(5, small.lines.size)
            assertEquals('@', small.lines[0].kind)

            assertTrue(client.getDiff("integration_claude", 2))
            val a = rec.diffParts.poll(10, TimeUnit.SECONDS)!!
            val b = rec.diffParts.poll(10, TimeUnit.SECONDS)!!
            assertEquals(listOf(0 to 2, 1 to 2), listOf(a.part to a.parts, b.part to b.parts))
            assertEquals(200, a.lines.size + b.lines.size)
            assertTrue(a.truncated)
            assertTrue("a long line is cut", (a.lines + b.lines).all { it.text.length <= Protocol.MAX_DIFF_LINE_CHARS })

            assertTrue(client.getDiff("integration_claude", 99))
            assertTrue(rec.diffParts.poll(10, TimeUnit.SECONDS)!!.gone)
        } finally {
            client.stop()
        }
    }

    @Test fun withoutTheSwitchTheNodeDesktopListsNoFilesAndAnswersNoRequest() {
        val info = startDesktop()
        val rec = Rec()
        val client = chatClient(info, rec)
        try {
            client.start()
            assertNotNull(rec.welcome.poll(10, TimeUnit.SECONDS))
            assertTrue(!client.getDiff("integration_claude", 1))
            assertNull(rec.diffParts.poll(2, TimeUnit.SECONDS))
            assertTrue(generateSequence { rec.sessions.poll(1, TimeUnit.SECONDS) }.take(3).all { l -> l.all { it.files.isEmpty() } })
        } finally {
            client.stop()
        }
    }

    @Test fun withoutTheSwitchTheNodeDesktopOffersNoQuestion() {
        val info = startDesktop()
        val rec = Rec()
        val client = chatClient(info, rec)
        try {
            client.start()
            assertNotNull(rec.welcome.poll(10, TimeUnit.SECONDS))
            assertNull(rec.questions.poll(3, TimeUnit.SECONDS))
            assertTrue(!client.answer("a".repeat(64), listOf(listOf("x"))))
        } finally {
            client.stop()
        }
    }

    // ── chat, against the fake provider of the Node desktop ─────────────────────────

    @Test fun chatWorksAgainstTheFakeProvider() {
        val info = startDesktop("--fake-chat")
        val rec = Rec()
        val client = chatClient(info, rec)
        try {
            client.start()
            assertEquals(setOf("chat"), rec.caps.poll(10, TimeUnit.SECONDS))
            assertEquals("models:fake/echo,fake/other", rec.chat.poll(10, TimeUnit.SECONDS))
            assertTrue(client.chatSend("c1", "fake/echo", "hello there"))
            val (text, end) = rec.answer("c1")
            assertEquals("Fake answer to: hello there", text)
            assertEquals("done:-", end)

            // the desktop's own refusals arrive as codes
            client.chatSend("c2", "fake/echo", "/error")
            assertEquals("error:c2:provider", rec.answer("c2").second)
            client.chatSend("c3", "fake/echo", "/auth")
            assertEquals("error:c3:auth", rec.answer("c3").second)
            client.chatSend("c4", "not/allowed", "hi")
            assertEquals("error:c4:not_allowed", rec.answer("c4").second)
            client.chatSend("c5", "fake/echo", "x".repeat(Protocol.CHAT_MAX_TEXT + 1))
            assertEquals("error:c5:too_long", rec.answer("c5").second)

            // a long answer arrives in pieces that add up
            client.chatSend("c6", "fake/echo", "/long")
            val (long, longEnd) = rec.answer("c6")
            assertEquals("done:-", longEnd)
            assertEquals(750 * "Lorem ipsum dolor sit amet. ".length, long.length)

            // a rewritten answer is replaced by the final one
            client.chatSend("c7", "fake/echo", "/rewrite")
            assertEquals("done:Answer", rec.answer("c7").second)
        } finally {
            client.stop()
        }
    }

    @Test fun oneAnswerAtATimeAndCancelStopsIt() {
        val info = startDesktop("--fake-chat")
        val rec = Rec()
        val client = chatClient(info, rec)
        try {
            client.start()
            assertNotNull(rec.caps.poll(10, TimeUnit.SECONDS))
            client.chatSend("s1", "fake/echo", "/slow")
            assertTrue("never started", generateSequence { rec.chat.poll(5, TimeUnit.SECONDS) }.take(20).any { it.startsWith("delta:s1:") })
            client.chatSend("s2", "fake/echo", "second")
            assertEquals("error:s2:busy", rec.answer("s2").second)
            client.chatCancel("s1")
            assertEquals("error:s1:canceled", rec.answer("s1").second)
            client.chatSend("s3", "fake/echo", "after")
            assertEquals("Fake answer to: after", rec.answer("s3").first)
        } finally {
            client.stop()
        }
    }

    @Test fun anOlderAppOrAnOlderComputerSeesNoChat() {
        // The desktop has chat but the app asks for nothing (an older app): not offered, nothing sent.
        val info = startDesktop("--fake-chat")
        val rec = Rec()
        val client = chatClient(info, rec, caps = emptyList())
        try {
            client.start()
            assertEquals(emptySet<String>(), rec.caps.poll(10, TimeUnit.SECONDS))
            client.chatSend("o1", "fake/echo", "hi")
            assertNull(rec.chat.poll(1, TimeUnit.SECONDS))
        } finally {
            client.stop()
        }
    }

    @Test fun aDesktopWithoutTheFakeProviderOffersNoChat() {
        val info = startDesktop()
        val rec = Rec()
        val client = chatClient(info, rec)
        try {
            client.start()
            assertEquals(emptySet<String>(), rec.caps.poll(10, TimeUnit.SECONDS))
            assertNull(rec.chat.poll(1, TimeUnit.SECONDS))
        } finally {
            client.stop()
        }
    }

    // ── session details, against the Node desktop ─────────────────────────────────────────

    /** The first sessions message that has Claude Code in it. */
    private fun claudeSession(rec: Rec): SessionInfo {
        val deadline = System.currentTimeMillis() + 15_000
        while (System.currentTimeMillis() < deadline) {
            val list = rec.sessions.poll(1, TimeUnit.SECONDS) ?: continue
            list.firstOrNull { it.pillId == "integration_claude" }?.let { return it }
        }
        error("no Claude Code session arrived")
    }

    @Test fun detailsArriveWhenTheDesktopOffersThem() {
        val info = startDesktop("--details")
        val rec = Rec()
        val client = chatClient(info, rec)
        try {
            client.start()
            assertEquals(setOf("details"), rec.caps.poll(10, TimeUnit.SECONDS))
            val s = claudeSession(rec)
            assertTrue(s.steps.isNotEmpty() && s.steps.first().startsWith("Read"))
            assertEquals("coucou", s.project)
            assertEquals("#2DD4BF", s.color)
        } finally {
            client.stop()
        }
    }

    @Test fun anOlderAppGetsPlainSessionsFromADesktopThatHasDetails() {
        val info = startDesktop("--details")
        val rec = Rec()
        val client = chatClient(info, rec, caps = emptyList())
        try {
            client.start()
            assertEquals(emptySet<String>(), rec.caps.poll(10, TimeUnit.SECONDS))
            val s = claudeSession(rec)
            assertEquals(emptyList<String>(), s.steps)
            assertNull(s.project); assertNull(s.color); assertNull(s.finalLine)
        } finally {
            client.stop()
        }
    }

    @Test fun aDesktopWithoutDetailsSendsNoneEvenToAnAppThatAsks() {
        val info = startDesktop() // no --details: an older desktop
        val rec = Rec()
        val client = chatClient(info, rec)
        try {
            client.start()
            assertEquals(emptySet<String>(), rec.caps.poll(10, TimeUnit.SECONDS))
            val s = claudeSession(rec)
            assertEquals(emptyList<String>(), s.steps)
            assertNull(s.project)
        } finally {
            client.stop()
        }
    }
}
