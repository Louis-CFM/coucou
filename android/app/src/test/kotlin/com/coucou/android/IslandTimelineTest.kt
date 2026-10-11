package com.coucou.android

import com.coucou.android.core.IslandSpec
import com.coucou.android.core.IslandTimeline
import com.coucou.android.core.IslandTimeline.Phase
import com.coucou.android.mochi.BotState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class IslandTimelineTest {
    private var now = 1_000.0
    private val t = IslandTimeline { now }

    private fun spec(kind: IslandSpec.Kind, state: BotState, text: String = "") = IslandSpec(kind, "agent_gemini", "Gemini CLI", state, text)
    private val working = spec(IslandSpec.Kind.WORKING, BotState.WORKING, "Runs npm test")
    private val finished = spec(IslandSpec.Kind.FINISHED, BotState.FINISHED, "All done")
    private val error = spec(IslandSpec.Kind.ERROR, BotState.ERROR, "Build failed")
    private val limit = spec(IslandSpec.Kind.RATELIMIT, BotState.RATELIMIT)
    private val approval = spec(IslandSpec.Kind.APPROVAL, BotState.APPROVAL, "Bash: rm -rf x")
    private val question = spec(IslandSpec.Kind.QUESTION, BotState.QUESTION)

    private fun advance(ms: Double) { now += ms; t.tick() }

    @Test fun nothingIsScheduledWhileHidden() {
        assertEquals(Phase.HIDDEN, t.phase)
        assertNull(t.nextDeadline())
        assertNull(t.current)
    }

    @Test fun workingOpensTheIslandAndKeepsItOpenWithoutAnyTimer() {
        t.setActive(working)
        assertEquals(Phase.OPEN, t.phase)
        assertEquals(working, t.current)
        assertNull("no deadline while it works", t.nextDeadline())
        advance(3_600_000.0)
        assertEquals(Phase.OPEN, t.phase)
    }

    @Test fun finishingHoldsTenSecondsThenRetracts() {
        t.setActive(working)
        t.setActive(null)          // the agent stopped working...
        t.flash(finished)          // ...and finished
        assertEquals("the island does not retract in between", Phase.OPEN, t.phase)
        assertEquals(finished, t.current)
        assertEquals(now + 10_000.0, t.nextDeadline()!!, 0.0)

        advance(9_999.0)
        assertEquals(Phase.OPEN, t.phase)
        advance(1.0)
        assertEquals(Phase.RETRACTING, t.phase)
        assertEquals("it shrinks around what it showed", finished, t.current)
        assertEquals(now + 340.0, t.nextDeadline()!!, 0.0)

        advance(340.0)
        assertEquals(Phase.HIDDEN, t.phase)
        assertNull(t.current)
        assertNull(t.nextDeadline())
    }

    @Test fun errorsAndRateLimitsAlsoWaitTenSeconds() {
        for (s in listOf(error, limit)) {
            t.dismiss()
            t.flash(s)
            advance(9_000.0)
            assertEquals(Phase.OPEN, t.phase)
            advance(1_000.0)
            assertEquals(Phase.RETRACTING, t.phase)
        }
    }

    @Test fun aNewerEventRestartsTheHold() {
        t.flash(finished)
        advance(8_000.0)
        t.flash(error)
        assertEquals(error, t.current)
        advance(8_000.0)
        assertEquals("16 s after the first event but only 8 after the second", Phase.OPEN, t.phase)
        advance(2_000.0)
        assertEquals(Phase.RETRACTING, t.phase)
    }

    @Test fun aRequestOrAQuestionStaysUntilAnsweredOrExpired() {
        t.setActive(approval)
        advance(125_000.0)
        assertEquals("a request has no 10 s limit", Phase.OPEN, t.phase)
        assertNull(t.nextDeadline())
        t.setActive(null) // answered, or expired
        assertEquals(Phase.RETRACTING, t.phase)

        t.dismiss()
        t.setActive(question)
        advance(60_000.0)
        assertEquals(Phase.OPEN, t.phase)
    }

    @Test fun aRequestOutranksAFinishedNoticeAndTheNoticeStillHoldsAfterwards() {
        t.flash(finished)
        advance(2_000.0)
        t.setActive(approval)
        assertEquals(approval, t.current)
        assertNull("a request pins the island", t.nextDeadline())
        advance(4_000.0)
        t.setActive(null) // answered after 4 s
        assertEquals("the finished notice is still inside its 10 s", finished, t.current)
        assertEquals(Phase.OPEN, t.phase)
        advance(4_000.0)
        assertEquals(Phase.RETRACTING, t.phase)
    }

    @Test fun aNewSessionStartingWhileItRetractsReopensIt() {
        t.flash(finished)
        advance(10_000.0)
        assertEquals(Phase.RETRACTING, t.phase)
        advance(100.0)
        t.setActive(working)
        assertEquals(Phase.OPEN, t.phase)
        assertEquals(working, t.current)
        assertNull(t.nextDeadline())
        advance(1_000.0)
        assertEquals(Phase.OPEN, t.phase)
    }

    @Test fun theWindowCanGoOnceTheRetractIsFinished() {
        t.flash(finished)
        advance(10_000.0)
        t.retractFinished()
        assertEquals(Phase.HIDDEN, t.phase)
        assertNull(t.nextDeadline())
    }

    @Test fun dismissClosesAtOnceAndForgetsEverything() {
        t.setActive(working)
        t.flash(finished)
        t.dismiss()
        assertEquals(Phase.HIDDEN, t.phase)
        assertNull(t.current)
        assertNull(t.nextDeadline())
        advance(60_000.0)
        assertEquals("a forgotten notice must not come back", Phase.HIDDEN, t.phase)
    }

    @Test fun workingWinsOverAFinishedNoticeFromAnotherSession() {
        t.flash(finished)
        t.setActive(working)
        assertEquals(working, t.current)
        assertTrue(t.nextDeadline() == null)
    }
}
