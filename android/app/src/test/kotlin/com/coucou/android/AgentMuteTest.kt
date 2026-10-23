package com.coucou.android

import com.coucou.android.core.AgentMute
import com.coucou.android.core.StatusPolicy
import com.coucou.android.core.UserSettings
import com.coucou.android.mochi.BotState
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentMuteTest {
    private val muted = UserSettings(mutedAgents = setOf("agent_codex"))
    private fun announce(now: BotState, s: UserSettings, id: String?) = StatusPolicy.announce(BotState.WORKING, now, s, 12 * 60, appInForeground = false, pillId = id)

    @Test fun nobodyIsMutedByDefault() {
        assertEquals(emptySet<String>(), UserSettings().mutedAgents)
        assertTrue(announce(BotState.FINISHED, UserSettings(), "agent_codex").notify)
    }

    @Test fun aMutedAgentIsQuietWhenItFinishesFailsOrHitsALimit() {
        for (state in listOf(BotState.FINISHED, BotState.ERROR, BotState.RATELIMIT)) {
            assertEquals(state.name, com.coucou.android.core.Announce.NONE, announce(state, muted, "agent_codex"))
        }
    }

    @Test fun otherAgentsAreNotAffected() {
        assertTrue(announce(BotState.FINISHED, muted, "integration_claude").notify)
        assertTrue(announce(BotState.FINISHED, muted, null).notify)
    }

    @Test fun aQuestionIsNeverMuted() {
        val a = announce(BotState.QUESTION, muted, "agent_codex")
        assertTrue(a.notify && a.sound && a.pill)
    }

    @Test fun anApprovalIsNeverMuted() {
        assertTrue(StatusPolicy.stateSoundWanted(BotState.WORKING, BotState.APPROVAL, muted))
        // Even with every agent muted and the other notices off.
        val all = UserSettings(notifyDone = false, mutedAgents = AgentMute.candidates.map { it.id }.toSet())
        assertTrue(StatusPolicy.stateSoundWanted(BotState.WORKING, BotState.APPROVAL, all))
        assertTrue(announce(BotState.QUESTION, all, "agent_gemini").notify)
    }

    @Test fun theChoiceIsStoredAsAShortCleanList() {
        assertEquals("agent_codex,agent_gemini", AgentMute.encode(setOf("agent_gemini", "agent_codex")))
        assertEquals(setOf("agent_codex"), AgentMute.decode(" agent_codex ,ai_openai,../x,,<b>"))
        assertEquals(emptySet<String>(), AgentMute.decode(null))
        assertEquals(setOf("agent_codex"), AgentMute.with(emptySet(), "agent_codex", true))
        assertEquals(emptySet<String>(), AgentMute.with(setOf("agent_codex"), "agent_codex", false))
        assertEquals(emptySet<String>(), AgentMute.with(emptySet(), "ai_openai", true))
    }

    @Test fun theIslandFlashFollowsTheSameRule() {
        val src = File("src/main/kotlin/com/coucou/android/core/IslandPlan.kt").readText()
        assertTrue(src.contains("pillId = session.pillId"))
        assertTrue(File("src/main/kotlin/com/coucou/android/app/AppModel.kt").readText().contains("StatusPolicy.announce(prev, s.state, settings, minute, inForeground, s.pillId)"))
    }

    @Test fun approvalsDoNotReadTheMuteList() {
        for (f in listOf("app/Notifications.kt", "core/ApprovalAlerts.kt", "core/OverlayPolicy.kt")) {
            assertFalse(f, File("src/main/kotlin/com/coucou/android/$f").readText().contains("mutedAgents"))
        }
        val model = File("src/main/kotlin/com/coucou/android/app/AppModel.kt").readText()
        assertFalse(model.substringAfter("override fun onApproval(").substringBefore("override fun onQuestion").contains("mutedAgents"))
    }
}
