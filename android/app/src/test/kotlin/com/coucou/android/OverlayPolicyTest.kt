package com.coucou.android

import com.coucou.android.core.OverlayChoice
import com.coucou.android.core.OverlayPolicy
import com.coucou.android.core.WishStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OverlayPolicyTest {
    @Test fun onlyShownWhenWantedPermittedAndYouAreElsewhere() {
        assertTrue(OverlayPolicy.shouldShow(enabled = true, permitted = true, appInForeground = false))
        assertFalse(OverlayPolicy.shouldShow(enabled = false, permitted = true, appInForeground = false))
        assertFalse(OverlayPolicy.shouldShow(enabled = true, permitted = false, appInForeground = false))
        assertFalse(OverlayPolicy.shouldShow(enabled = true, permitted = true, appInForeground = true))
    }

    @Test fun theReasonItStaysAwayIsNamed() {
        assertEquals("switch is off", OverlayPolicy.blocker(false, true, false))
        assertTrue(OverlayPolicy.blocker(true, false, false)!!.contains("not allowed"))
        assertEquals("the app is on screen", OverlayPolicy.blocker(true, true, true))
        assertEquals(null, OverlayPolicy.blocker(true, true, false))
    }

    private class Memory : WishStore {
        var saved = false
        var writes = 0
        override fun read() = saved
        override fun write(on: Boolean) { saved = on; writes++ }
    }

    @Test fun theWishIsSavedAtTheTapEvenIfThePermissionIsNotThereYet() {
        val disk = Memory()
        OverlayChoice(disk).choose(true) // tap; Android now opens its settings screen
        assertTrue(disk.saved)
        // Android killed and restarted the app while the user was in Settings: a new object, same disk.
        val afterRestart = OverlayChoice(disk)
        assertTrue(afterRestart.wished)
        assertFalse(afterRestart.active(permitted = false)) // still waiting for the system permission
        assertTrue(afterRestart.active(permitted = true)) // granted: works without another tap
    }

    @Test fun grantingThePermissionLaterFromAndroidSettingsIsEnough() {
        val choice = OverlayChoice(Memory().apply { saved = true })
        var permitted = false
        assertFalse(choice.active(permitted))
        permitted = true // the user allowed it in Android's own settings
        assertTrue(choice.active(permitted))
    }

    @Test fun switchingOffIsRememberedAndNeverShowsAgain() {
        val disk = Memory().apply { saved = true }
        val choice = OverlayChoice(disk)
        choice.choose(false)
        assertFalse(OverlayChoice(disk).active(permitted = true))
    }

    @Test fun withThePillOnScreenTheNotificationIsQuiet() {
        // Regression: the expanded pill and Android's heads-up notification overlapped at the top.
        assertEquals(OverlayPolicy.ApprovalAlert.QUIET, OverlayPolicy.approvalAlert(pillShown = true))
        assertEquals(OverlayPolicy.ApprovalAlert.HEADS_UP, OverlayPolicy.approvalAlert(pillShown = false))
    }

    @Test fun theHeadsUpComesBackWhenThePillCannotShow() {
        for ((enabled, permitted, foreground) in listOf(
            Triple(false, true, false), Triple(true, false, false), Triple(true, true, true),
        )) {
            val pill = OverlayPolicy.shouldShow(enabled, permitted, foreground)
            assertEquals(OverlayPolicy.ApprovalAlert.HEADS_UP, OverlayPolicy.approvalAlert(pill))
        }
    }

    @Test fun aTapInTheFirstMomentsIsIgnored() {
        // Regression: a tap meant for the app underneath, while the pill slides in, hit Allow / open.
        assertFalse(OverlayPolicy.tapAccepted(shownAtMs = 1_000.0, nowMs = 1_050.0))
        assertFalse(OverlayPolicy.tapAccepted(shownAtMs = 1_000.0, nowMs = 1_599.0))
        assertTrue(OverlayPolicy.tapAccepted(shownAtMs = 1_000.0, nowMs = 1_600.0))
        assertTrue(OverlayPolicy.tapAccepted(shownAtMs = 1_000.0, nowMs = 9_000.0))
    }
}
