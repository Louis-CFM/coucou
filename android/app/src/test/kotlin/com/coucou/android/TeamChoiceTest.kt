package com.coucou.android

import com.coucou.android.core.GlanceBuilder
import com.coucou.android.core.TeamChoice
import com.coucou.android.core.WidgetData
import com.coucou.android.core.WidgetTile
import com.coucou.android.core.WidgetTone
import com.coucou.android.link.SessionInfo
import com.coucou.android.mochi.BotState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TeamChoiceTest {
    private fun tile(id: String, name: String, state: BotState, word: String = "word") = WidgetTile(id, name, state, word, 0xFF112233.toInt())
    private val running = listOf(
        tile("integration_claude", "Claude Code", BotState.APPROVAL, "Waiting for your approval"),
        tile("agent_codex", "Codex", BotState.WORKING, "Working"),
        tile("agent_gemini", "Gemini CLI", BotState.FINISHED, "Finished"),
    )

    @Test fun onlyAgentsAndWorkspaceToolsCanBePicked() {
        val ids = TeamChoice.candidates.map { it.id }
        assertTrue("agent_codex" in ids && "integration_claude" in ids && "agent_gemini" in ids)
        assertFalse("ai_openai" in ids)
        assertFalse("integration_stripe" in ids)
        assertEquals(ids.size, ids.toSet().size)
    }

    @Test fun aChoiceIsStoredAsACleanShortList() {
        assertEquals("agent_codex,agent_gemini", TeamChoice.encode(listOf("agent_codex", "agent_gemini")))
        assertEquals(listOf("agent_codex", "agent_gemini"), TeamChoice.decode("agent_codex,agent_gemini"))
        assertEquals(emptyList<String>(), TeamChoice.decode(null))
        assertEquals(emptyList<String>(), TeamChoice.decode(""))
    }

    @Test fun anythingThatIsNotACatalogAgentIsDroppedOnTheWayIn() {
        assertEquals(listOf("agent_codex"), TeamChoice.decode(" agent_codex , ai_openai,../x,,agent_codex,<b>"))
        assertEquals(emptyList<String>(), TeamChoice.decode("a".repeat(10_000)))
        assertEquals("agent_codex", TeamChoice.encode(listOf("agent_codex", "not-an-agent", "agent_codex")))
    }

    @Test fun nobodyHoldsMoreThanTheMaximum() {
        val six = TeamChoice.candidates.take(6).map { it.id }
        assertEquals(six.take(TeamChoice.MAX), TeamChoice.decode(six.joinToString(",")))
        assertEquals(TeamChoice.MAX, TeamChoice.encode(six).split(",").size)
    }

    @Test fun togglingAddsAtTheEndRemovesAndStopsAtTheMaximum() {
        var chosen = emptyList<String>()
        val ids = TeamChoice.candidates.map { it.id }
        for (id in ids.take(TeamChoice.MAX)) chosen = TeamChoice.toggle(chosen, id)
        assertEquals(ids.take(TeamChoice.MAX), chosen)
        // Full: another one is refused, the picked ones can still be removed.
        assertFalse(TeamChoice.canToggle(chosen, ids[TeamChoice.MAX]))
        assertEquals(chosen, TeamChoice.toggle(chosen, ids[TeamChoice.MAX]))
        assertTrue(TeamChoice.canToggle(chosen, ids[0]))
        assertEquals(ids.slice(1 until TeamChoice.MAX), TeamChoice.toggle(chosen, ids[0]))
        // Not a catalog id: nothing happens.
        assertEquals(chosen, TeamChoice.toggle(chosen, "ai_openai"))
        assertFalse(TeamChoice.canToggle(emptyList(), "ai_openai"))
    }

    @Test fun theRowsAreTheChosenAgentsInTheChosenOrder() {
        val rows = TeamChoice.rows(true, running, listOf("agent_gemini", "integration_claude"), "Not running")
        assertEquals(listOf("agent_gemini", "integration_claude"), rows.map { it.pillId })
        assertEquals(running[2], rows[0])
    }

    @Test fun aChosenAgentThatDoesNotRunIsShownAsNotRunning() {
        val rows = TeamChoice.rows(true, running, listOf("agent_codex", "agent_amp"), "Not running")
        assertEquals(listOf("Codex", "Amp"), rows.map { it.name })
        assertEquals("Not running", rows[1].stateWord)
        assertEquals(BotState.IDLE, rows[1].state)
        assertEquals(WidgetTone.IDLE, rows[1].tone)
    }

    @Test fun theClaudeCodeHookKeepsItsName() {
        assertEquals("Claude Code", TeamChoice.nameOf("integration_claude"))
        assertEquals("Codex", TeamChoice.nameOf("agent_codex"))
        assertEquals("Claude Code", TeamChoice.rows(true, emptyList(), listOf("integration_claude"), "Not running")[0].name)
    }

    @Test fun withNothingChosenItShowsTheBusiestAgents() {
        val many = (1..6).map { tile("agent_$it", "A$it", BotState.WORKING) }
        assertEquals(many.take(TeamChoice.MAX), TeamChoice.rows(true, many, emptyList(), "Not running"))
        assertEquals(emptyList<WidgetTile>(), TeamChoice.rows(true, emptyList(), emptyList(), "Not running"))
    }

    @Test fun whenTheComputerIsNotThereThereAreNoRows() {
        assertEquals(emptyList<WidgetTile>(), TeamChoice.rows(false, running, listOf("agent_codex"), "Not running"))
    }

    @Test fun anAgentBeyondTheListsFiveRowsStillShowsItsRealState() {
        // Seven agents run; the one picked is the least urgent. It must not be reported as "not running".
        val sessions = (1..7).map { SessionInfo("agent_$it", "Agent $it", if (it == 7) BotState.IDLE else BotState.WORKING, "", 0, 0, 0L) } +
            SessionInfo("agent_codex", "Codex", BotState.IDLE, "", 0, 0, 0L)
        val glance = GlanceBuilder.build(true, com.coucou.android.link.LinkState.CONNECTED, "PC", sessions, 0) { it }
        val content = WidgetData.build(glance, sessions, nameOf = { it })
        assertTrue(content.tiles.size <= WidgetData.MAX_ROWS)
        assertTrue(content.roster.any { it.pillId == "agent_codex" })
        val rows = TeamChoice.rows(true, content.roster, listOf("agent_codex"), "Not running")
        assertEquals(BotState.IDLE, rows.single().state)
        assertTrue(rows.single().stateWord != "Not running")
    }

    @Test fun theLookIsTheMostUrgentOfWhatIsShown() {
        assertEquals(WidgetTone.MUTED, TeamChoice.look(false, running))
        assertEquals(WidgetTone.ATTENTION, TeamChoice.look(true, running))
        assertEquals(WidgetTone.WORKING, TeamChoice.look(true, running.drop(1)))
        assertEquals(WidgetTone.DONE, TeamChoice.look(true, running.drop(2)))
        assertEquals(WidgetTone.IDLE, TeamChoice.look(true, emptyList()))
        assertEquals(WidgetTone.TROUBLE, TeamChoice.look(true, listOf(tile("a", "A", BotState.ERROR), tile("b", "B", BotState.WORKING))))
    }

    @Test fun theSpokenCardNamesEveryAgentOrSaysTheEmptyLine() {
        val said = TeamChoice.spoken(running, "Nothing")
        assertTrue(said.contains("Claude Code") && said.contains("Codex") && said.contains("Gemini CLI"))
        assertEquals("No agents running", TeamChoice.spoken(emptyList(), "No agents running"))
    }
}
