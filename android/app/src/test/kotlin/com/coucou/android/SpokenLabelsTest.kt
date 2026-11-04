package com.coucou.android

import com.coucou.android.core.SpokenLabels
import org.junit.Assert.assertEquals
import org.junit.Test

class SpokenLabelsTest {
    @Test fun anAgentIsSpokenWithItsStateInWords() {
        assertEquals("Claude Code, waiting for your OK", SpokenLabels.agent("Claude Code", "Waiting for your OK", null))
        assertEquals("Claude Code, working. Editing files", SpokenLabels.agent("Claude Code", "Working", "Editing files"))
    }

    @Test fun aLineThatRepeatsTheStateIsNotSaidTwice() {
        assertEquals("Codex, working", SpokenLabels.agent("Codex", "Working", "Working"))
        assertEquals("Codex, working", SpokenLabels.agent("Codex", "Working", "working"))
        assertEquals("Codex, working", SpokenLabels.agent("Codex", "Working", "  "))
    }

    @Test fun aMissingNameOrStateStillGivesASentence() {
        assertEquals("Waiting for your OK", SpokenLabels.agent("", "Waiting for your OK", null))
        assertEquals("Claude Code", SpokenLabels.agent("Claude Code", "", null))
        assertEquals("", SpokenLabels.agent("", "", null))
    }

    @Test fun anApprovalNamesTheAgentAndTheAction() {
        assertEquals("Approval needed: Claude Code wants to run a command", SpokenLabels.approval("Approval needed", "Claude Code", "Wants to run a command"))
        assertEquals("Approval needed: Wants to run a command", SpokenLabels.approval("Approval needed", " ", "Wants to run a command"))
    }

    @Test fun aTabWithTheAlertDotSaysWhy() {
        assertEquals("Home", SpokenLabels.tab("Home", false, "Home, a request is waiting"))
        assertEquals("Home, a request is waiting", SpokenLabels.tab("Home", true, "Home, a request is waiting"))
    }
}
