package com.coucou.android

import com.coucou.android.core.IslandGeometry
import com.coucou.android.core.IslandPlan
import com.coucou.android.core.IslandSpec
import com.coucou.android.core.PxRect
import com.coucou.android.core.QuietHours
import com.coucou.android.core.UserSettings
import com.coucou.android.link.ApprovalRequest
import com.coucou.android.link.SessionInfo
import com.coucou.android.mochi.BotState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class IslandPlanTest {
    private val name = { id: String -> if (id == "a") "Alpha" else "Beta" }
    private fun s(id: String, st: BotState, text: String = "") = SessionInfo(id, "", st, text, 0, 0, 0L)
    private val request = ApprovalRequest("a", "f".repeat(64), "Bash", "ls", 0L)
    private val noon = 12 * 60
    private val settings = UserSettings()

    @Test fun theIslandOffersAllowOnlyForACommandThatIsShownWhole() {
        assertTrue(IslandPlan.active(emptyList(), listOf(request), true, name)!!.canAllow)
        assertFalse(IslandPlan.active(emptyList(), listOf(request.copy(truncated = true)), true, name)!!.canAllow)
    }

    @Test fun workingShowsWhenAllowedAndNeverWhenNot() {
        val list = listOf(s("a", BotState.WORKING, "Runs tests"))
        assertEquals(IslandSpec.Kind.WORKING, IslandPlan.active(list, emptyList(), allowed = true, name)!!.kind)
        assertNull(IslandPlan.active(list, emptyList(), allowed = false, name))
    }

    @Test fun thinkingAndSearchingCountAsWorking() {
        for (st in listOf(BotState.THINKING, BotState.SEARCHING)) {
            assertEquals(IslandSpec.Kind.WORKING, IslandPlan.active(listOf(s("a", st)), emptyList(), true, name)!!.kind)
        }
    }

    @Test fun aRequestComesBeforeAQuestionBeforeWork() {
        val all = listOf(s("a", BotState.WORKING), s("b", BotState.QUESTION))
        assertEquals(IslandSpec.Kind.QUESTION, IslandPlan.active(all, emptyList(), true, name)!!.kind)
        val withRequest = IslandPlan.active(all, listOf(request), true, name)!!
        assertEquals(IslandSpec.Kind.APPROVAL, withRequest.kind)
        assertEquals("the island says what kind of action, never the command", "run a command", withRequest.text)
        assertEquals("Alpha", withRequest.agent)
    }

    @Test fun idleSleepingFinishedAreNotAnActiveState() {
        for (st in listOf(BotState.IDLE, BotState.SLEEPING, BotState.FINISHED, BotState.ERROR, BotState.DIZZY)) {
            assertNull("$st", IslandPlan.active(listOf(s("a", st)), emptyList(), true, name))
        }
    }

    @Test fun finishingFlashesOnAChangeOnly() {
        val done = s("a", BotState.FINISHED, "All done")
        val spec = IslandPlan.flash(BotState.WORKING, done, settings, noon, true, name)
        assertEquals(IslandSpec.Kind.FINISHED, spec!!.kind)
        assertEquals("free text from the computer is not shown", "", spec.text)
        assertNull("the first picture after connecting", IslandPlan.flash(null, done, settings, noon, true, name))
        assertNull("the same state again", IslandPlan.flash(BotState.FINISHED, done, settings, noon, true, name))
    }

    @Test fun errorsAndLimitsFlashToo() {
        assertEquals(IslandSpec.Kind.ERROR, IslandPlan.flash(BotState.WORKING, s("a", BotState.ERROR), settings, noon, true, name)!!.kind)
        assertEquals(IslandSpec.Kind.RATELIMIT, IslandPlan.flash(BotState.WORKING, s("a", BotState.RATELIMIT), settings, noon, true, name)!!.kind)
    }

    @Test fun theUsersSwitchesAreRespected() {
        val done = s("a", BotState.FINISHED)
        assertNull("not allowed (switch off, no permission or app on screen)", IslandPlan.flash(BotState.WORKING, done, settings, noon, false, name))
        assertNull("notice switch off", IslandPlan.flash(BotState.WORKING, done, settings.copy(notifyDone = false), noon, true, name))
        val quiet = settings.copy(quiet = QuietHours(true, 22 * 60, 8 * 60))
        assertNull("quiet hours", IslandPlan.flash(BotState.WORKING, done, quiet, 23 * 60, true, name))
        assertNotNull("outside quiet hours", IslandPlan.flash(BotState.WORKING, done, quiet, noon, true, name))
    }

    @Test fun workingIsNotGatedByTheFinishedSwitchOrQuietHours() {
        val list = listOf(s("a", BotState.WORKING))
        // The user asked: working shows with the overlay; the notice switch and quiet hours govern finished/failed.
        assertNotNull(IslandPlan.active(list, emptyList(), true, name))
    }

    @Test fun theIslandNeverShowsWhileCoucouIsOpen() {
        assertTrue(IslandPlan.allowed(overlayOn = true, permitted = true, appInForeground = false))
        assertTrue(!IslandPlan.allowed(overlayOn = true, permitted = true, appInForeground = true))
        assertTrue(!IslandPlan.allowed(overlayOn = false, permitted = true, appInForeground = false))
        assertTrue(!IslandPlan.allowed(overlayOn = true, permitted = false, appInForeground = false))
    }

    // ── geometry ────────────────────────────────────────────────────────────

    @Test fun theIslandIsCentredOnTheCameraCutoutAndHangsBelowIt() {
        // Galaxy A12s: 720 px wide, a centred waterdrop about 70 px wide and 66 px tall.
        val box = IslandGeometry.place(720, 2f, PxRect(325, 0, 395, 66), statusBarH = 70)
        assertEquals(0, box.centerOffsetX)
        assertEquals("content starts under the cut-out", 66, box.topInset)
        assertTrue(box.workingH > box.topInset)
        assertTrue(box.cardH > box.workingH && box.approvalH > box.cardH)
        assertTrue(box.workingW <= 720 && box.approvalW <= 720)
    }

    @Test fun anOffCentreCutoutMovesTheIslandButItStaysOnScreen() {
        val left = IslandGeometry.place(720, 2f, PxRect(80, 0, 150, 60), statusBarH = 60)
        assertTrue(left.centerOffsetX < 0)
        val maxOffset = (720 - left.approvalW) / 2
        assertTrue(left.centerOffsetX >= -maxOffset)
    }

    @Test fun withoutACutoutItHangsFromTheStatusBarAtTheCentre() {
        val box = IslandGeometry.place(1080, 3f, null, statusBarH = 72)
        assertEquals(0, box.centerOffsetX)
        assertEquals(72, box.topInset)
    }

    @Test fun anEmptyOrBrokenCutoutIsIgnored() {
        val box = IslandGeometry.place(720, 2f, PxRect(0, 0, 0, 0), statusBarH = 50)
        assertEquals(50, box.topInset)
        assertEquals(0, box.centerOffsetX)
    }

    @Test fun sizesFollowTheKindOfContent() {
        val box = IslandGeometry.place(720, 2f, null, 48)
        assertEquals(box.workingW to box.workingH, IslandGeometry.sizeFor(box, IslandSpec.Kind.WORKING))
        assertEquals(box.approvalW to box.approvalH, IslandGeometry.sizeFor(box, IslandSpec.Kind.APPROVAL))
        assertEquals(box.cardW to box.cardH, IslandGeometry.sizeFor(box, IslandSpec.Kind.FINISHED))
        assertEquals(box.cardW to box.cardH, IslandGeometry.sizeFor(box, IslandSpec.Kind.QUESTION))
    }

    @Test fun theIslandSaysWhatTheAgentDoesNotTheRawToolName() {
        val w = IslandPlan.active(listOf(s("a", BotState.WORKING, "ask_question")), emptyList(), true, name)!!
        assertEquals("Asking a question", w.text)
        val f = IslandPlan.flash(BotState.WORKING, s("a", BotState.FINISHED, "Bash"), settings, noon, true, name)!!
        assertEquals("Running a command", f.text)
    }
}
