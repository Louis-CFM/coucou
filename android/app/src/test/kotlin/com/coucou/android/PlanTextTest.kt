package com.coucou.android

import com.coucou.android.core.PlanText
import com.coucou.android.link.PlanWindow
import java.time.ZoneId
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors the rules of windows/src/core/plan.ts so the phone and the PC read the same numbers the same way. */
class PlanTextTest {
    private val now = 1_800_000_000_000L

    @Test fun aWindowThatHasResetCountsAsZero() {
        assertEquals(0, PlanText.effectivePct(PlanWindow(90, now - 1), now))
        assertEquals(0, PlanText.effectivePct(PlanWindow(90, now), now))
        assertEquals(90, PlanText.effectivePct(PlanWindow(90, now + 1), now))
    }

    @Test fun greenUnderFiftyOrangeUpToEightyRedAbove() {
        assertEquals(PlanText.Level.LOW, PlanText.level(49))
        assertEquals(PlanText.Level.MEDIUM, PlanText.level(50))
        assertEquals(PlanText.Level.MEDIUM, PlanText.level(79))
        assertEquals(PlanText.Level.HIGH, PlanText.level(80))
        assertEquals(PlanText.Level.HIGH, PlanText.level(100))
        assertEquals(PlanText.Level.LOW, PlanText.level(0))
    }

    @Test fun resetTimesReadLikeThePCs() {
        assertEquals(PlanText.Reset.Now, PlanText.resetsIn(PlanWindow(1, now), now))
        assertEquals(PlanText.Reset.InMinutes(5), PlanText.resetsIn(PlanWindow(1, now + 5 * 60_000 + 10_000), now))
        assertEquals(PlanText.Reset.InHoursMinutes(1, 20), PlanText.resetsIn(PlanWindow(1, now + 80 * 60_000), now))
        assertEquals(PlanText.Reset.InMinutes(0), PlanText.resetsIn(PlanWindow(1, now + 30_000), now))
    }

    @Test fun theWeekShowsADayAndATimeInTheLocalZone() {
        // 2027-01-18 09:00 in Paris (UTC+1) is a Monday.
        val w = PlanWindow(1, java.time.ZonedDateTime.of(2027, 1, 18, 9, 5, 0, 0, ZoneId.of("Europe/Paris")).toInstant().toEpochMilli())
        assertEquals("Mon 9:05", PlanText.weekday(w, ZoneId.of("Europe/Paris"), Locale.ENGLISH))
        assertTrue(PlanText.weekday(w, ZoneId.of("Asia/Tokyo"), Locale.ENGLISH).startsWith("Mon 17:05"))
    }

    @Test fun theLevelsAreTheOnesInThePCsSource() {
        val ts = ReferenceFiles.read("windows/src/core/plan.ts")
        assertTrue(ts.contains("if (pct < 50) return \"#22C55E\"") && ts.contains("if (pct < 80) return \"#F59E0B\""))
        assertTrue(ts.contains("w.resetsAt <= now ? 0 : w.usedPct"))
    }
}
