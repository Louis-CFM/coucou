package com.coucou.android

import com.coucou.android.core.Glance
import com.coucou.android.core.GlanceBuilder
import com.coucou.android.core.GlanceTone
import com.coucou.android.link.LinkState
import com.coucou.android.link.SessionInfo
import com.coucou.android.mochi.BotState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GlanceTest {
    private fun s(id: String, state: BotState, status: String = "") = SessionInfo(id, "", state, status, 0, 0, 0L)
    private val names = mapOf("a" to "Claude Code", "b" to "Codex", "c" to "Gemini")
    private fun build(
        sessions: List<SessionInfo> = emptyList(), approvals: Int = 0, link: LinkState = LinkState.CONNECTED,
        paired: Boolean = true, desktop: String? = "Léa's PC",
    ): Glance = GlanceBuilder.build(paired, link, desktop, sessions, approvals) { names[it] ?: "An agent" }

    @Test fun notPairedInvitesToConnect() {
        val g = build(paired = false)
        assertEquals("Not paired", g.headline)
        assertFalse(g.connected)
        assertEquals(GlanceTone.CALM, g.tone)
    }

    @Test fun aLostLinkSaysSoAndShowsNoAgents() {
        val g = build(listOf(s("a", BotState.WORKING)), link = LinkState.DISCONNECTED)
        assertEquals("Not connected", g.headline)
        assertTrue(g.lines.isEmpty())
        assertEquals("Connecting…", build(link = LinkState.CONNECTING).headline)
    }

    @Test fun idleAndConnected() {
        val g = build()
        assertEquals("Connected", g.headline)
        assertEquals("To Léa's PC", g.detail)
        assertEquals(GlanceTone.OK, g.tone)
    }

    @Test fun oneAgentWorking() {
        val g = build(listOf(s("a", BotState.WORKING)))
        assertEquals("Claude Code is working", g.headline)
        assertEquals(GlanceTone.BUSY, g.tone)
    }

    @Test fun severalAgentsWorkingAreCounted() {
        val g = build(listOf(s("a", BotState.WORKING), s("b", BotState.THINKING), s("c", BotState.SEARCHING)))
        assertEquals("3 agents are working", g.headline)
    }

    @Test fun anApprovalBeatsEverything() {
        val g = build(listOf(s("a", BotState.ERROR), s("b", BotState.WORKING)), approvals = 2)
        assertEquals("Waiting for you", g.headline)
        assertEquals("2 requests to approve", g.detail)
        assertEquals(2, g.waiting)
        assertEquals(GlanceTone.ATTENTION, g.tone)
    }

    @Test fun aQuestionCountsAsWaiting() {
        val g = build(listOf(s("a", BotState.QUESTION), s("b", BotState.WORKING)))
        assertEquals("Waiting for your answer", g.headline)
        assertEquals(1, g.waiting)
    }

    @Test fun troubleBeatsWork() {
        val g = build(listOf(s("a", BotState.WORKING), s("b", BotState.ERROR)))
        assertEquals("An agent needs a look", g.headline)
        assertEquals("1 agent stopped", g.detail)
        assertEquals(GlanceTone.TROUBLE, g.tone)
    }

    @Test fun finishedWhenNothingElseIsGoingOn() {
        assertEquals("All done", build(listOf(s("a", BotState.FINISHED))).headline)
    }

    @Test fun linesAreUrgentFirstAndLimited() {
        val many = listOf(
            s("a", BotState.IDLE), s("b", BotState.WORKING), s("c", BotState.ERROR),
            s("a", BotState.FINISHED), s("b", BotState.QUESTION), s("c", BotState.SLEEPING),
        )
        val g = build(many)
        assertEquals(GlanceBuilder.MAX_LINES, g.lines.size)
        assertEquals(listOf(BotState.QUESTION, BotState.ERROR, BotState.WORKING, BotState.FINISHED), g.lines.map { it.state })
    }

    @Test fun neitherAStepNorACommandNorAFileNameIsEverShown() {
        val secret = listOf(
            s("a", BotState.WORKING, "Edit · /home/me/secret/plan.md"),
            s("b", BotState.SEARCHING, "Running rm -rf build"),
            s("c", BotState.THINKING, "token sk-12345"),
        )
        val g = build(secret, desktop = null)
        val everything = (listOf(g.headline, g.detail) + g.lines.flatMap { listOf(it.agent, it.text) }).joinToString("|")
        for (leak in listOf("secret", "plan.md", "rm -rf", "sk-12345", "/home")) assertFalse(leak, everything.contains(leak))
    }

    @Test fun workingLinesUseOnlyTheStateWord() {
        val g = build(listOf(s("a", BotState.WORKING, "Bash"), s("b", BotState.SEARCHING, "Grep"), s("c", BotState.THINKING, "x")))
        assertEquals(setOf("Working", "Searching", "Thinking"), g.lines.map { it.text }.toSet())
    }
}
