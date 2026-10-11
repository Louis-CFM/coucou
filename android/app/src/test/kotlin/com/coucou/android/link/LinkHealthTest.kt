package com.coucou.android.link

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LinkHealthTest {
    private val min = 60_000L

    @Test fun theTimeAgoIsInPlainWords() {
        assertEquals("less than a minute", LinkHealthText.ago(0))
        assertEquals("less than a minute", LinkHealthText.ago(59_999))
        assertEquals("1 min", LinkHealthText.ago(min))
        assertEquals("2 min", LinkHealthText.ago(2 * min + 5_000))
        assertEquals("59 min", LinkHealthText.ago(59 * min))
        assertEquals("1 h", LinkHealthText.ago(60 * min))
        assertEquals("1 h 5 min", LinkHealthText.ago(65 * min))
        assertEquals("3 h", LinkHealthText.ago(180 * min))
        assertEquals("less than a minute", LinkHealthText.ago(-5))
    }

    @Test fun homeSaysWhatHappenedAndHowLongAgo() {
        val h = LinkHealth().lost(atMs = 1_000_000, why = LostReason.SILENT, screenWasOff = true)
        val (head, why) = LinkHealthText.lines(connected = false, health = h, nowMs = 1_000_000 + 2 * min)!!
        assertEquals("Connection lost 2 min ago, reconnecting", head)
        assertTrue(why.contains("phone slept"))
        assertTrue(LinkHealthText.lines(false, h.copy(reason = LostReason.CLOSED), 1_000_000)!!.second.contains("closed"))
        assertTrue(LinkHealthText.lines(false, h.copy(reason = LostReason.NETWORK), 1_000_000)!!.second.contains("network"))
    }

    @Test fun nothingIsSaidWhenConnectedOrWhenNothingWasLost() {
        val h = LinkHealth().lost(1_000, LostReason.NETWORK, false)
        assertNull(LinkHealthText.lines(connected = true, health = h, nowMs = 5_000))
        assertNull(LinkHealthText.lines(connected = false, health = LinkHealth(), nowMs = 5_000))
        assertNull(LinkHealthText.lines(connected = false, health = h.recovered(), nowMs = 5_000))
    }

    @Test fun repeatedFailuresAreCountedAfterTheThird() {
        val h = LinkHealth().lost(0, LostReason.NETWORK, false)
        assertFalse(LinkHealthText.lines(false, h.failedAttempt(2), 0)!!.first.contains("tries"))
        assertTrue(LinkHealthText.lines(false, h.failedAttempt(5), 0)!!.first.endsWith("(5 tries)"))
    }

    @Test fun theDropsWhileTheScreenWasOffAreCountedAndSurviveARecovery() {
        var h = LinkHealth()
        h = h.lost(1, LostReason.SILENT, screenWasOff = false)
        assertEquals(0, h.dropsWhileScreenOff)
        h = h.recovered().lost(2, LostReason.SILENT, screenWasOff = true)
        h = h.recovered().lost(3, LostReason.CLOSED, screenWasOff = true)
        assertEquals(2, h.dropsWhileScreenOff)
        assertEquals(2, h.recovered().dropsWhileScreenOff)
        assertNull(h.recovered().lostAtMs)
    }

    // ── the alarm and the battery hint ──

    @Test fun theAlarmIsArmedOnlyForARealPairing() {
        assertTrue(KeepAlivePolicy.shouldArm(paired = true, demo = false))
        assertFalse(KeepAlivePolicy.shouldArm(paired = false, demo = false))
        assertFalse(KeepAlivePolicy.shouldArm(paired = true, demo = true))
    }

    @Test fun theComputerToleratesSeveralMissedChecks() {
        assertTrue(KeepAlivePolicy.COMPUTER_IDLE_MS >= 4 * KeepAlivePolicy.INTERVAL_MS)
        assertTrue("Doze can stretch the alarm to about 15 minutes", KeepAlivePolicy.COMPUTER_IDLE_MS > 15 * min)
        assertTrue(KeepAlivePolicy.WAKE_LOCK_MS <= 30_000)
    }

    @Test fun theBatteryHintComesOnlyWhenItWouldHelp() {
        val dropped = LinkHealth(dropsWhileScreenOff = 1)
        fun show(paired: Boolean = true, h: LinkHealth = dropped, ignoring: Boolean = false, snoozed: Long? = null, now: Long = 10_000_000_000) =
            BatteryHint.shouldShow(paired, h, ignoring, snoozed, now)
        assertTrue(show())
        assertFalse("never dropped", show(h = LinkHealth()))
        assertFalse("already unrestricted", show(ignoring = true))
        assertFalse("not paired", show(paired = false))
        assertFalse("said not now yesterday", show(snoozed = 10_000_000_000 - 24 * 3_600_000L))
        assertTrue("asks again after a week", show(snoozed = 10_000_000_000 - BatteryHint.SNOOZE_MS))
    }

    @Test fun samsungGetsTheTwoPlacesAndOthersOne() {
        assertTrue(BatteryHint.isSamsung("samsung"))
        assertTrue(BatteryHint.isSamsung("Samsung"))
        assertFalse(BatteryHint.isSamsung("Google"))
        val s = BatteryHint.steps(samsung = true)
        assertEquals(2, s.size)
        assertTrue(s[0].contains("Unrestricted") && s[1].contains("Sleeping apps") && s[1].contains("Never sleeping apps"))
        assertEquals(1, BatteryHint.steps(samsung = false).size)
    }
}
