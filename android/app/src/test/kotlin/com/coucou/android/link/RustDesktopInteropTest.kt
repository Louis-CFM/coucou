package com.coucou.android.link

import com.coucou.android.ReferenceFiles
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.PrintWriter
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * The real [LinkClient] against the real desktop server of the Windows/Linux app
 * (windows/src-tauri/src/phone_link), a separate implementation of docs/ANDROID_LINK.md in Rust
 * with its own TLS stack (rustls) and its own certificate.
 *
 * The server is the ignored cargo test `phone_link::interop::interop_server`, started here and
 * driven over stdin. Compiling it takes minutes, so this only runs when COUCOU_RUST_INTEROP=1
 * (the `interop` job in .github/workflows/android.yml sets it) and cargo is installed.
 */
class RustDesktopInteropTest {
    private var proc: Process? = null
    private var stdin: PrintWriter? = null
    private val lines = LinkedBlockingQueue<String>()

    @After fun cleanup() {
        stdin?.println("quit")
        stdin?.flush()
        proc?.waitFor(5, TimeUnit.SECONDS)
        proc?.destroyForcibly()
    }

    private fun startDesktop(): JSONObject {
        assumeTrue("set COUCOU_RUST_INTEROP=1 to run against the Rust desktop", System.getenv("COUCOU_RUST_INTEROP") == "1")
        val manifest = ReferenceFiles.file("windows/Cargo.toml").absolutePath
        proc = try {
            ProcessBuilder(
                "cargo", "test", "--manifest-path", manifest, "-p", "coucou", "--lib", "--locked", "--",
                "--ignored", "--nocapture", "phone_link::interop::interop_server",
            ).redirectErrorStream(true).start()
        } catch (_: Exception) {
            assumeTrue("cargo not available", false)
            return JSONObject()
        }
        stdin = PrintWriter(proc!!.outputStream, true)
        Thread {
            BufferedReader(InputStreamReader(proc!!.inputStream)).forEachLine { lines.add(it) }
        }.apply { isDaemon = true; start() }
        // The first start compiles the whole app: allow for it.
        val deadline = System.currentTimeMillis() + 20 * 60_000
        while (System.currentTimeMillis() < deadline) {
            val l = lines.poll(5, TimeUnit.SECONDS) ?: continue
            if (l.startsWith("{\"listening\"")) return JSONObject(l)
        }
        error("the Rust desktop did not start")
    }

    /** Sends one command and waits until the desktop has done it. */
    private fun command(text: String) {
        stdin!!.println(text)
        val deadline = System.currentTimeMillis() + 10_000
        while (System.currentTimeMillis() < deadline) {
            val l = lines.poll(1, TimeUnit.SECONDS) ?: continue
            if (l == "OK $text") return
        }
        error("no answer to '$text'")
    }

    /** True if the desktop printed [expected] within [seconds]. */
    private fun sawLine(expected: String, seconds: Long): Boolean {
        val deadline = System.currentTimeMillis() + seconds * 1000
        while (System.currentTimeMillis() < deadline) {
            val l = lines.poll(200, TimeUnit.MILLISECONDS) ?: continue
            if (l == expected) return true
        }
        return false
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
        val caps = LinkedBlockingQueue<Set<String>>()
        val chat = LinkedBlockingQueue<String>()
        // "prefs" (the outfit) is offered to every app that asks, so the other tests leave it out; it has its own test.
        override fun onCaps(caps: Set<String>) { this.caps.add(caps - Protocol.CAP_PREFS); allCaps.add(caps) }
        val allCaps = LinkedBlockingQueue<Set<String>>()
        val prefs = LinkedBlockingQueue<String>()
        val serviceCards = LinkedBlockingQueue<List<ServiceCard>>()
        override fun onServices(cards: List<ServiceCard>) { serviceCards.add(cards) }
        val usages = LinkedBlockingQueue<UsageSnapshot>()
        override fun onUsage(usage: UsageSnapshot) { usages.add(usage) }
        val recaps = LinkedBlockingQueue<java.util.Optional<Recap>>()
        override fun onRecap(recap: Recap?) { recaps.add(java.util.Optional.ofNullable(recap)) }
        val diffParts = LinkedBlockingQueue<ServerMsg.Diff>()
        override fun onDiff(part: ServerMsg.Diff) { diffParts.add(part) }
        override fun onPrefs(outfit: String) { prefs.add(outfit) }
        override fun onChatModels(models: List<ChatModel>) { chat.add("models:" + models.joinToString(",") { it.id }) }
        override fun onChatDelta(id: String, text: String) { chat.add("delta:$id:$text") }
        override fun onChatDone(id: String, text: String?) { chat.add("done:$id:${text ?: "-"}") }
        override fun onChatError(id: String, reason: String, message: String) { chat.add("error:$id:$reason") }

        fun answer(id: String, seconds: Long = 15): Pair<String, String> {
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

    private fun chatClient(info: JSONObject, rec: Rec, caps: List<String> = Protocol.CAPABILITIES): LinkClient {
        val client = LinkClient(PairingPayload.parse(info.getString("link"))!!, "Interop Pixel", rec, readTimeoutMs = 5_000, caps = caps)
        client.start()
        return client
    }

    private fun connect(info: JSONObject, rec: Rec, token: String? = null): LinkClient {
        val pairing = PairingPayload.parse(info.getString("link"))
        assertNotNull("the Rust desktop's pairing link was not accepted: ${info.getString("link")}", pairing)
        val client = LinkClient(if (token == null) pairing!! else pairing!!.copy(token = token), "Interop Pixel", rec, readTimeoutMs = 5_000)
        client.start()
        return client
    }

    @Test fun pairsReceivesSessionsAndApprovalAndAllows() {
        val info = startDesktop()
        val rec = Rec()
        val client = connect(info, rec)
        try {
            assertEquals("Rust desktop", rec.welcome.poll(15, TimeUnit.SECONDS))
            command("sessions")
            var sessions = rec.sessions.poll(10, TimeUnit.SECONDS)
            while (sessions != null && sessions.isEmpty()) sessions = rec.sessions.poll(10, TimeUnit.SECONDS)
            assertNotNull("no sessions arrived", sessions)
            assertEquals(listOf("integration_claude", "agent_gemini"), sessions!!.map { it.pillId })
            assertEquals("Claude Code", sessions[0].agent)
            assertEquals(2, sessions[0].stepIndex)
            assertEquals(6, sessions[0].stepCount)

            command("approval req-1 npm run build")
            val req = rec.approvals.poll(10, TimeUnit.SECONDS)
            assertNotNull("no approval request arrived", req)
            assertEquals("npm run build", req!!.command)
            assertEquals("Bash", req.tool)
            // The Rust fingerprint must be the one the Mac-compatible Kotlin derivation yields.
            assertEquals(Fingerprint.of("integration_claude", "interop", "Bash", "npm run build", "req-1"), req.fingerprint)

            assertTrue(client.decide(req.fingerprint, allow = true))
            assertEquals(req.fingerprint, rec.resolved.poll(10, TimeUnit.SECONDS))
            assertTrue("the desktop never applied the decision", sawLine("DECISION allow req-1", 10))
        } finally {
            client.stop()
        }
    }

    @Test fun aCommandOf10000CharactersIsFlaggedAndCannotBeAllowedFromThePhone() {
        val info = startDesktop()
        val rec = Rec()
        val client = connect(info, rec)
        try {
            assertNotNull(rec.welcome.poll(15, TimeUnit.SECONDS))
            command("approval req-long " + "x".repeat(10_000))
            val req = rec.approvals.poll(10, TimeUnit.SECONDS)!!
            assertTrue(req.truncated)
            assertEquals(500, req.command.length)
            assertFalse(com.coucou.android.core.ApprovalSheetPlan.canAllowHere(req))
            // Even a phone that asks anyway is not obeyed.
            client.decide(req.fingerprint, allow = true)
            assertFalse("the desktop must not apply Allow for a cut command", sawLine("DECISION allow req-long", 2))
        } finally {
            client.stop()
        }
    }

    @Test fun denyReachesTheDesktop() {
        val info = startDesktop()
        val rec = Rec()
        val client = connect(info, rec)
        try {
            assertNotNull(rec.welcome.poll(15, TimeUnit.SECONDS))
            command("approval req-9 rm -rf build")
            val req = rec.approvals.poll(10, TimeUnit.SECONDS)!!
            assertTrue(client.decide(req.fingerprint, allow = false))
            assertTrue(sawLine("DECISION deny req-9", 10))
        } finally {
            client.stop()
        }
    }

    @Test fun aRequestAnsweredAtTheDeskCannotBeAnsweredFromThePhone() {
        val info = startDesktop()
        val rec = Rec()
        val client = connect(info, rec)
        try {
            assertNotNull(rec.welcome.poll(15, TimeUnit.SECONDS))
            command("approval req-2 ls")
            val req = rec.approvals.poll(10, TimeUnit.SECONDS)!!
            command("clear") // allowed on the desktop
            assertEquals(req.fingerprint, rec.resolved.poll(10, TimeUnit.SECONDS))
            assertFalse("the phone no longer offers it", client.decide(req.fingerprint, allow = true))
            assertFalse(sawLine("DECISION allow req-2", 1))
        } finally {
            client.stop()
        }
    }

    @Test fun aWrongTokenIsRefused() {
        val info = startDesktop()
        val rec = Rec()
        val client = connect(info, rec, token = "x".repeat(30))
        try {
            assertEquals("auth", rec.errors.poll(15, TimeUnit.SECONDS))
            assertNull(rec.welcome.poll(1, TimeUnit.SECONDS))
        } finally {
            client.stop()
        }
    }

    @Test fun pairingAgainDisconnectsThePhoneThatHadTheOldCode() {
        val info = startDesktop()
        val rec = Rec()
        val client = connect(info, rec)
        try {
            assertNotNull(rec.welcome.poll(15, TimeUnit.SECONDS))
            command("repair brand-new-token-0123456789")
            assertEquals("auth", rec.errors.poll(10, TimeUnit.SECONDS))
        } finally {
            client.stop()
        }
    }

    // ── Service cards (cap services) ────────────────────────────────────────────────

    @Test fun theRealServerSendsOnlyTheServicesTheUserTicked() {
        val info = startDesktop()
        command("services stripe")
        command("servicecards")
        val rec = Rec()
        val client = chatClient(info, rec)
        try {
            assertEquals(setOf("services"), rec.caps.poll(15, TimeUnit.SECONDS))
            val cards = rec.serviceCards.poll(10, TimeUnit.SECONDS)!!
            assertEquals(listOf("integration_stripe"), cards.map { it.id })
            assertTrue("the Notion card was not ticked: its text must not arrive", cards.none { c -> c.items.any { it.label == "Private page" } })
            assertNull(rec.serviceCards.poll(1, TimeUnit.SECONDS))
        } finally {
            client.stop()
        }
    }

    @Test fun withNothingTickedTheRealServerOffersNoServices() {
        val info = startDesktop()
        command("servicecards")
        val rec = Rec()
        val client = chatClient(info, rec)
        try {
            assertEquals(emptySet<String>(), rec.caps.poll(15, TimeUnit.SECONDS))
            assertNull(rec.serviceCards.poll(2, TimeUnit.SECONDS))
        } finally {
            client.stop()
        }
    }

    // ── Plan usage (cap usage) ──────────────────────────────────────────────────────

    @Test fun theRealServerSendsTheUsageToAnAppThatAsksWhileTheSwitchIsOn() {
        val info = startDesktop()
        command("usage on")
        command("usagepct 62.6")
        val rec = Rec()
        val client = chatClient(info, rec)
        val old = Rec()
        val oldClient = chatClient(info, old, caps = emptyList())
        try {
            assertEquals(setOf("prefs", "usage"), rec.allCaps.poll(15, TimeUnit.SECONDS))
            val first = rec.usages.poll(10, TimeUnit.SECONDS)!!
            assertEquals(PlanWindow(63, 1_900_000_000_000), first.claude!!.fiveHour)
            assertEquals("max", first.claude!!.plan)
            command("usagepct 80")
            assertEquals(80, rec.usages.poll(10, TimeUnit.SECONDS)!!.claude!!.fiveHour!!.pct)
            assertNull("an app that did not ask hears nothing", old.usages.poll(1, TimeUnit.SECONDS))
        } finally {
            client.stop()
            oldClient.stop()
        }
    }

    @Test fun withTheSwitchOffTheRealServerOffersNoUsage() {
        val info = startDesktop()
        command("usagepct 50")
        val rec = Rec()
        val client = chatClient(info, rec)
        try {
            assertEquals(emptySet<String>(), rec.caps.poll(15, TimeUnit.SECONDS))
            assertNull(rec.usages.poll(2, TimeUnit.SECONDS))
        } finally {
            client.stop()
        }
    }

    // ── Weekly recap (cap recap) ────────────────────────────────────────────────────

    @Test fun theRealServerSendsLastWeeksCountsToAnAppThatAsksWhileTheSwitchIsOn() {
        val info = startDesktop()
        command("recap on")
        command("recapweek 2026-10-05")
        val rec = Rec()
        val client = chatClient(info, rec)
        val old = Rec()
        val oldClient = chatClient(info, old, caps = emptyList())
        try {
            assertEquals(setOf("prefs", "recap"), rec.allCaps.poll(15, TimeUnit.SECONDS))
            val r = rec.recaps.poll(10, TimeUnit.SECONDS)!!.get()
            assertEquals(Recap("2026-10-05", 340, 12, 40, 900, 210, 55, 20, 3, "Claude Code", null), r)
            command("recapnone")
            assertTrue("the card goes", !rec.recaps.poll(10, TimeUnit.SECONDS)!!.isPresent)
            assertNull("an app that did not ask hears nothing", old.recaps.poll(1, TimeUnit.SECONDS))
        } finally {
            client.stop()
            oldClient.stop()
        }
    }

    @Test fun withTheSwitchOffTheRealServerOffersNoRecap() {
        val info = startDesktop()
        command("recapweek 2026-10-05")
        val rec = Rec()
        val client = chatClient(info, rec)
        try {
            assertEquals(emptySet<String>(), rec.caps.poll(15, TimeUnit.SECONDS))
            assertNull(rec.recaps.poll(2, TimeUnit.SECONDS))
        } finally {
            client.stop()
        }
    }

    // ── File changes (cap diffs) ────────────────────────────────────────────────────

    /** The connection number the desktop printed for a request, or null. */
    private fun connOfRequest(seconds: Long): String? {
        val deadline = System.currentTimeMillis() + seconds * 1000
        while (System.currentTimeMillis() < deadline) {
            val l = lines.poll(200, TimeUnit.MILLISECONDS) ?: continue
            if (l.startsWith("GETDIFF ")) return l.split(" ")[1]
        }
        return null
    }

    @Test fun theRealServerListsFilesByNameAndSendsAFileOnRequestOnly() {
        val info = startDesktop()
        command("diffs on")
        command("sessions")
        val rec = Rec()
        val client = chatClient(info, rec)
        try {
            assertEquals(setOf("diffs"), rec.caps.poll(15, TimeUnit.SECONDS))
            val s = generateSequence { rec.sessions.poll(10, TimeUnit.SECONDS) }.take(5).first { l -> l.any { it.files.isNotEmpty() } }
            val file = s.first { it.files.isNotEmpty() }.files[0]
            assertEquals("a full path went in; only the name comes out", "app.ts", file.name)
            assertEquals(7L, file.id)
            assertNull("nothing is sent before it is asked for", rec.diffParts.poll(1, TimeUnit.SECONDS))

            assertTrue(client.getDiff("integration_claude", 7))
            val conn = connOfRequest(10)
            assertNotNull("the island was never asked", conn)
            command("diff $conn 250")
            val a = rec.diffParts.poll(10, TimeUnit.SECONDS)!!
            val b = rec.diffParts.poll(10, TimeUnit.SECONDS)!!
            assertEquals(200, a.lines.size + b.lines.size)
            assertTrue(a.truncated)
            assertEquals("app.ts", a.name)
        } finally {
            client.stop()
        }
    }

    @Test fun withTheSwitchOffTheRealServerOffersNoFilesAndIgnoresTheRequest() {
        val info = startDesktop()
        command("sessions")
        val rec = Rec()
        val client = chatClient(info, rec)
        try {
            assertEquals(emptySet<String>(), rec.caps.poll(15, TimeUnit.SECONDS))
            assertTrue(!client.getDiff("integration_claude", 7))
            assertTrue(generateSequence { rec.sessions.poll(2, TimeUnit.SECONDS) }.take(3).all { l -> l.all { it.files.isEmpty() } })
        } finally {
            client.stop()
        }
    }

    // ── Mochi's outfit (cap prefs) ─────────────────────────────────────────────────

    @Test fun theOutfitReachesAnAppThatAsksAndNobodyElse() {
        val info = startDesktop()
        command("outfit beanie")
        val rec = Rec()
        val client = chatClient(info, rec)
        val old = Rec()
        val oldClient = chatClient(info, old, caps = emptyList())
        try {
            assertEquals(setOf("prefs"), rec.allCaps.poll(15, TimeUnit.SECONDS))
            assertEquals("beanie", rec.prefs.poll(10, TimeUnit.SECONDS))
            command("outfit crown")
            assertEquals("crown", rec.prefs.poll(10, TimeUnit.SECONDS))
            command("outfit topHat") // not a wardrobe value: never sent
            command("outfit auto")
            assertEquals("auto", rec.prefs.poll(10, TimeUnit.SECONDS))
            assertEquals(emptySet<String>(), old.allCaps.poll(15, TimeUnit.SECONDS))
            assertNull("an app that did not ask hears nothing", old.prefs.poll(1, TimeUnit.SECONDS))
        } finally {
            client.stop()
            oldClient.stop()
        }
    }

    // ── chat, against the real server with a fake provider ───────────────────────────

    @Test fun chatWorksAgainstTheRealServerWhenItsSwitchIsOn() {
        val info = startDesktop()
        command("chat on")
        val rec = Rec()
        val client = chatClient(info, rec)
        try {
            assertEquals(setOf("chat"), rec.caps.poll(15, TimeUnit.SECONDS))
            assertEquals("models:anthropic/fake-claude,openai/fake-gpt", rec.chat.poll(10, TimeUnit.SECONDS))
            assertTrue(client.chatSend("c1", "openai/fake-gpt", "hello"))
            val (text, end) = rec.answer("c1")
            assertEquals("echo from openai/fake-gpt: hello", text)
            assertEquals("done:-", end)

            client.chatSend("c2", "openai/fake-gpt", "/error")
            assertEquals("error:c2:provider", rec.answer("c2").second)
            client.chatSend("c3", "openai/fake-gpt", "/auth")
            assertEquals("error:c3:auth", rec.answer("c3").second)
            client.chatSend("c4", "ollama/not-allowed", "hi")
            assertEquals("error:c4:not_allowed", rec.answer("c4").second)
            client.chatSend("c5", "openai/fake-gpt", "x".repeat(Protocol.CHAT_MAX_TEXT + 1))
            assertEquals("error:c5:too_long", rec.answer("c5").second)

            client.chatSend("s1", "openai/fake-gpt", "/slow")
            assertTrue("never started", generateSequence { rec.chat.poll(5, TimeUnit.SECONDS) }.take(20).any { it.startsWith("delta:s1:") })
            client.chatSend("s2", "openai/fake-gpt", "second")
            assertEquals("error:s2:busy", rec.answer("s2").second)
            client.chatCancel("s1")
            assertEquals("error:s1:canceled", rec.answer("s1").second)

            // New chat: the computer forgets its side
            client.chatReset()
            assertTrue(sawLine("CHAT reset", 10))
        } finally {
            client.stop()
        }
    }

    @Test fun withTheSwitchOffTheServerOffersNoChat() {
        val info = startDesktop()
        val rec = Rec()
        val client = chatClient(info, rec)
        try {
            assertEquals(emptySet<String>(), rec.caps.poll(15, TimeUnit.SECONDS))
            client.chatSend("o1", "openai/fake-gpt", "hi")
            assertNull(rec.chat.poll(1, TimeUnit.SECONDS))
        } finally {
            client.stop()
        }
    }

    @Test fun anOlderAppIsNeverOfferedChatEvenWhenItIsOn() {
        val info = startDesktop()
        command("chat on")
        val rec = Rec()
        val client = chatClient(info, rec, caps = emptyList())
        try {
            assertEquals(emptySet<String>(), rec.caps.poll(15, TimeUnit.SECONDS))
            client.chatSend("o1", "openai/fake-gpt", "hi")
            assertNull(rec.chat.poll(1, TimeUnit.SECONDS))
        } finally {
            client.stop()
        }
    }

    // ── session details, against the real server ──────────────────────────────────────────

    private fun claude(rec: Rec): SessionInfo {
        val deadline = System.currentTimeMillis() + 15_000
        while (System.currentTimeMillis() < deadline) {
            val list = rec.sessions.poll(1, TimeUnit.SECONDS) ?: continue
            list.firstOrNull { it.pillId == "integration_claude" }?.let { return it }
        }
        error("no Claude Code session arrived")
    }

    @Test fun detailsArriveFromTheRealServerWhenItsSwitchIsOn_andNeverAPath() {
        val info = startDesktop()
        command("details on")
        command("sessions")
        val rec = Rec()
        val client = chatClient(info, rec)
        try {
            assertEquals(setOf("details"), rec.caps.poll(15, TimeUnit.SECONDS))
            val s = claude(rec)
            assertEquals(listOf("Read · README.md", "Edit · src/app.ts"), s.steps)
            assertEquals("Fixed the bug", s.finalLine)
            assertEquals("proj", s.project)
            assertEquals("#2DD4BF", s.color)
        } finally {
            client.stop()
        }
    }

    @Test fun withTheSwitchOffTheRealServerSendsNoDetailsToAnAppThatAsks() {
        val info = startDesktop()
        command("sessions")
        val rec = Rec()
        val client = chatClient(info, rec)
        try {
            assertEquals(emptySet<String>(), rec.caps.poll(15, TimeUnit.SECONDS))
            val s = claude(rec)
            assertEquals(emptyList<String>(), s.steps)
            assertNull(s.project); assertNull(s.finalLine); assertNull(s.color)
        } finally {
            client.stop()
        }
    }

    @Test fun anOlderAppGetsTheV1SessionsFromTheRealServerEvenWithDetailsOn() {
        val info = startDesktop()
        command("details on")
        command("sessions")
        val rec = Rec()
        val client = chatClient(info, rec, caps = emptyList())
        try {
            assertEquals(emptySet<String>(), rec.caps.poll(15, TimeUnit.SECONDS))
            val s = claude(rec)
            assertEquals("Editing files", s.statusText)
            assertEquals(emptyList<String>(), s.steps)
            assertNull(s.project)
        } finally {
            client.stop()
        }
    }
}
