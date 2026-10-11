package com.coucou.android.link

import com.coucou.android.mochi.BotState

/**
 * Offline demo of the desktop link: a few fake sessions and one approval, so the app can be
 * tried (and tested) without a desktop. It never opens a socket, and a "decision" made here
 * only changes the demo; nothing is sent anywhere.
 */
class DemoLink(
    private val listener: LinkListener,
    private val clockMs: () -> Long = System::currentTimeMillis,
    /** Pause between script steps; tests pass 0 and call [step] themselves. */
    private val stepDelayMs: Long = 2_500,
    private val autoRun: Boolean = true,
) : DesktopLink {
    override val approvals = ApprovalBook(clockMs)

    @Volatile private var running = false
    @Volatile private var thread: Thread? = null
    private var cursor = 0

    companion object {
        const val SESSION_ID = "demo_session"
        const val TOOL = "Bash"
        const val COMMAND = "npm run build"
        val FINGERPRINT: String = Fingerprint.of("integration_claude", SESSION_ID, TOOL, COMMAND, "demo")
        const val STEPS = 8
    }

    private fun session(pill: String, agent: String, state: BotState, text: String, i: Int, n: Int) =
        SessionInfo(pill, agent, state, text, i, n, clockMs())

    @Synchronized override fun start() {
        if (running) return
        running = true
        listener.onState(LinkState.CONNECTED)
        listener.onWelcome("Demo", "demo")
        if (autoRun) thread = Thread({
            try {
                while (running) { step(); Thread.sleep(stepDelayMs) }
            } catch (_: InterruptedException) { }
        }, "coucou-demo").apply { isDaemon = true; start() }
    }

    @Synchronized override fun stop() {
        running = false
        thread?.interrupt()
        thread = null
        approvals.clear()
        listener.onState(LinkState.DISCONNECTED)
    }

    /** Advances the script by one step; loops forever. Public so tests can drive it. */
    @Synchronized fun step() {
        when (cursor % STEPS) {
            0 -> listener.onSessions(listOf(session("integration_claude", "Claude Code", BotState.THINKING, "Reading the project", 1, 6)))
            1 -> listener.onSessions(listOf(
                session("integration_claude", "Claude Code", BotState.WORKING, "Editing files", 2, 6),
                session("agent_codex", "Codex", BotState.SEARCHING, "Searching the code", 1, 4),
            ))
            2 -> {
                val r = ApprovalRequest("integration_claude", FINGERPRINT, TOOL, COMMAND, clockMs())
                approvals.add(r)
                listener.onSessions(listOf(
                    session("integration_claude", "Claude Code", BotState.APPROVAL, "Waiting for your approval", 3, 6),
                    session("agent_codex", "Codex", BotState.WORKING, "Running tests", 2, 4),
                ))
                listener.onApproval(r)
            }
            3 -> listener.onSessions(listOf(
                session("integration_claude", "Claude Code", BotState.WORKING, "Building", 4, 6),
                session("agent_codex", "Codex", BotState.QUESTION, "Which branch?", 3, 4),
            ))
            4 -> listener.onSessions(listOf(
                session("integration_claude", "Claude Code", BotState.FINISHED, "Done", 6, 6),
                session("agent_codex", "Codex", BotState.ERROR, "Tests failed", 3, 4),
            ))
            5 -> listener.onSessions(listOf(session("agent_codex", "Codex", BotState.RATELIMIT, "Rate limited", 3, 4)))
            6 -> listener.onSessions(listOf(session("agent_gemini", "Gemini CLI", BotState.SLEEPING, "Idle", 0, 0)))
            else -> {
                if (approvals.resolve(FINGERPRINT) != null) listener.onApprovalResolved(FINGERPRINT)
                listener.onSessions(emptyList())
            }
        }
        cursor++
    }

    override fun decide(fingerprint: String, allow: Boolean): Boolean {
        val r = approvals.claim(fingerprint) ?: return false
        listener.onApprovalResolved(r.fingerprint)
        return true
    }
}
