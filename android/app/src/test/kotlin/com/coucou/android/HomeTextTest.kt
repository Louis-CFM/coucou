package com.coucou.android

import com.coucou.android.core.HomeText
import com.coucou.android.core.ToolLabels
import com.coucou.android.link.SessionInfo
import com.coucou.android.mochi.BotState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class HomeTextTest {
    private fun s(state: BotState, status: String = "", final: String? = null) =
        SessionInfo("p", "A", state, status, 0, 0, 0L, finalLine = final)

    @Test fun aRawToolNameBecomesASentence() {
        assertEquals("Running a command", HomeText.line(s(BotState.WORKING, "Bash")))
        assertEquals("Editing files", HomeText.line(s(BotState.WORKING, "Edit · a.txt")))
    }

    @Test fun aFinishedAgentShowsItsLastMessage() {
        assertEquals("Migration applied.", HomeText.line(s(BotState.FINISHED, "Bash", "Migration applied.")))
        assertEquals("Running a command", HomeText.line(s(BotState.FINISHED, "Bash", "  ")))
    }

    @Test fun onlyAFinishedAgentShowsALastMessage() {
        assertEquals("Reading files", HomeText.line(s(BotState.WORKING, "Read", "old message")))
    }

    @Test fun nothingToSayIsNull() {
        assertNull(HomeText.line(s(BotState.IDLE)))
    }

    @Test fun requestsReadAsActions() {
        assertEquals("run a command", ToolLabels.action("Bash"))
        assertEquals("edit files", ToolLabels.action("multi_edit"))
        assertEquals("search the web", ToolLabels.action("WebSearch"))
        assertEquals("list issues", ToolLabels.action("list_issues"))
        assertEquals("do something", ToolLabels.action(" "))
    }

    @Test fun theRecentListSaysWhatYouDecided() {
        assertEquals("Allowed: edit files", HomeText.recent(true, "Edit"))
        assertEquals("Denied: run a command", HomeText.recent(false, "Bash"))
    }

    @Test fun runningCountsBusyAgentsOnly() {
        val all = listOf(s(BotState.WORKING), s(BotState.THINKING), s(BotState.SEARCHING), s(BotState.IDLE), s(BotState.APPROVAL), s(BotState.FINISHED))
        assertEquals(3, HomeText.running(all))
        assertEquals(0, HomeText.running(emptyList()))
    }

    @Test fun aDecisionIsASentenceWithNoCommand() {
        assertEquals("You allowed Claude Code to run a command", HomeText.decision(true, "Claude Code", "Bash"))
        assertEquals("You denied Codex to edit files", HomeText.decision(false, "Codex", "Edit"))
        assertEquals("You allowed an agent to read files", HomeText.decision(true, " ", "Read"))
    }
}
