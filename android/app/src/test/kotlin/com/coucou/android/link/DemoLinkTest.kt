package com.coucou.android.link

import com.coucou.android.mochi.BotState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DemoLinkTest {
    private class Rec : LinkListener {
        val states = mutableListOf<LinkState>()
        val sessions = mutableListOf<List<SessionInfo>>()
        val approvals = mutableListOf<ApprovalRequest>()
        val resolved = mutableListOf<String>()
        override fun onState(state: LinkState) { states.add(state) }
        override fun onSessions(sessions: List<SessionInfo>) { this.sessions.add(sessions) }
        override fun onApproval(request: ApprovalRequest) { approvals.add(request) }
        override fun onApprovalResolved(fingerprint: String) { resolved.add(fingerprint) }
    }

    private fun demo(rec: Rec) = DemoLink(rec, autoRun = false).also { it.start() }

    @Test fun startsConnected() {
        val rec = Rec()
        demo(rec)
        assertEquals(listOf(LinkState.CONNECTED), rec.states)
    }

    @Test fun scriptShowsEveryStateTheAppDraws() {
        val rec = Rec()
        val d = demo(rec)
        repeat(DemoLink.STEPS) { d.step() }
        val seen = rec.sessions.flatten().map { it.state }.toSet()
        for (s in listOf(BotState.THINKING, BotState.WORKING, BotState.SEARCHING, BotState.APPROVAL, BotState.QUESTION,
            BotState.ERROR, BotState.FINISHED, BotState.RATELIMIT, BotState.SLEEPING)) assertTrue("$s", s in seen)
    }

    @Test fun scriptLoopsForever() {
        val rec = Rec()
        val d = demo(rec)
        repeat(DemoLink.STEPS * 3) { d.step() }
        assertEquals(DemoLink.STEPS * 3, rec.sessions.size)
        assertEquals(3, rec.approvals.size)
    }

    @Test fun demoApprovalCanBeAnsweredOnceLocally() {
        val rec = Rec()
        val d = demo(rec)
        repeat(3) { d.step() }
        val req = rec.approvals.single()
        assertEquals(DemoLink.FINGERPRINT, req.fingerprint)
        assertTrue(Wire.isFingerprint(req.fingerprint))
        assertTrue(d.decide(req.fingerprint, allow = true))
        assertFalse(d.decide(req.fingerprint, allow = true))
        assertEquals(listOf(DemoLink.FINGERPRINT), rec.resolved)
    }

    @Test fun unansweredDemoApprovalIsRetractedAtTheEndOfTheLoop() {
        val rec = Rec()
        val d = demo(rec)
        repeat(DemoLink.STEPS) { d.step() }
        assertEquals(listOf(DemoLink.FINGERPRINT), rec.resolved)
        assertTrue(d.approvals.active().isEmpty())
    }

    @Test fun stopClearsPendingApprovals() {
        val rec = Rec()
        val d = demo(rec)
        repeat(3) { d.step() }
        d.stop()
        assertFalse(d.decide(DemoLink.FINGERPRINT, true))
        assertEquals(LinkState.DISCONNECTED, rec.states.last())
    }
}
