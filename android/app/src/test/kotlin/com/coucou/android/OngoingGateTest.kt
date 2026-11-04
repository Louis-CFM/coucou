package com.coucou.android

import com.coucou.android.core.Glance
import com.coucou.android.core.GlanceLine
import com.coucou.android.core.GlanceTone
import com.coucou.android.core.OngoingGate
import com.coucou.android.mochi.BotState
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OngoingGateTest {
    private fun glance(head: String = "1 agent working", detail: String = "Claude Code", waiting: Int = 0, tone: GlanceTone = GlanceTone.BUSY, state: BotState = BotState.WORKING) =
        Glance(head, detail, tone, true, listOf(GlanceLine("Claude Code", "Working", state)), waiting)

    @Test fun theFirstPushPosts() = assertTrue(OngoingGate().shouldPost(glance()))

    @Test fun thePushThatLooksTheSameIsDropped() {
        val gate = OngoingGate()
        assertTrue(gate.shouldPost(glance()))
        assertFalse(gate.shouldPost(glance()))
        assertFalse(gate.shouldPost(glance().copy(waiting = 0)))
    }

    @Test fun aChangeInTextOrColourPostsAgain() {
        val gate = OngoingGate()
        gate.shouldPost(glance())
        assertTrue(gate.shouldPost(glance(head = "All done")))
        assertTrue(gate.shouldPost(glance(head = "All done", detail = "2 finished")))
        assertTrue(gate.shouldPost(glance(head = "All done", detail = "2 finished", tone = GlanceTone.OK)))
        assertTrue(gate.shouldPost(glance(head = "All done", detail = "2 finished", tone = GlanceTone.OK).copy(lines = listOf(GlanceLine("Codex", "Done", BotState.FINISHED)))))
        assertTrue(gate.shouldPost(glance(head = "All done", detail = "2 finished", tone = GlanceTone.OK).copy(connected = false)))
    }

    @Test fun somethingThatIsNotOnTheNotificationDoesNotRepostIt() {
        val gate = OngoingGate()
        gate.shouldPost(glance(waiting = 0))
        // The count of waiting requests is not shown in the ongoing notification's text: the same text, the same notification.
        assertFalse(gate.shouldPost(glance(waiting = 3)))
        // The state of a line is not shown either, only its words.
        assertFalse(gate.shouldPost(glance(state = BotState.THINKING)))
    }

    @Test fun forgetMakesTheNextPushPost() {
        val gate = OngoingGate()
        gate.shouldPost(glance())
        gate.forget()
        assertTrue(gate.shouldPost(glance()))
    }

    @Test fun noGlanceYetIsOneKeyToo() {
        val gate = OngoingGate()
        assertTrue(gate.shouldPost(null))
        assertFalse(gate.shouldPost(null))
        assertTrue(gate.shouldPost(glance()))
    }
}
