package com.coucou.android

import com.coucou.android.core.Glance
import com.coucou.android.core.GlanceBuilder
import com.coucou.android.core.PlanUsageLook
import com.coucou.android.core.UsageRing
import com.coucou.android.core.UsageTone
import com.coucou.android.core.UsageSide
import com.coucou.android.core.WidgetData
import com.coucou.android.core.WidgetSample
import com.coucou.android.core.WidgetTone
import com.coucou.android.link.LinkState
import com.coucou.android.link.PlanUsage
import com.coucou.android.link.PlanWindow
import com.coucou.android.link.UsageSnapshot
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The plan-usage side of Mochi Big, in pure Kotlin: which rows, which colour, and which of the three things it shows. */
class WidgetUsageSideTest {
    private val now = 1_000_000L
    private val later = now + 3_600_000
    private fun five(p: Int, reset: Long = later) = PlanWindow(p, reset)

    private fun glance(link: LinkState = LinkState.CONNECTED): Glance = GlanceBuilder.build(true, link, "PC", emptyList(), 0) { "x" }
    private fun build(u: UsageSnapshot?, link: LinkState = LinkState.CONNECTED) = WidgetData.build(glance(link), emptyList(), { "x" }, u, today = 0, nowMs = now)

    // ── The colour comes from one function (PlanUsageLook, tested at its boundaries in PlanUsageLookTest) ──

    @Test fun theBarAndTheRingUseThePlanUsagePalette() {
        assertEquals(UsageTone.CALM, UsageRing("Claude", "5 h", 74).tone)
        assertEquals(UsageTone.CLOSE, UsageRing("Claude", "5 h", 75).tone)
        assertEquals(UsageTone.LIMIT, UsageRing("Codex", "week", 90).tone)
        assertEquals(PlanUsageLook.tone(60), UsageRing("Claude", "5 h", 60).tone)
    }

    // ── The rows ────────────────────────────────────────────────────────────────────────────────────

    @Test fun claudeThenCodexEachWithItsMainWindow() {
        val u = UsageSnapshot(PlanUsage(five(68), PlanWindow(10, later)), PlanUsage(null, PlanWindow(41, later)))
        assertEquals(listOf(UsageRing("Claude", "5 h", 68), UsageRing("Codex", "week", 41)), WidgetData.usageRows(u, now))
        assertEquals("Claude · 5 h", WidgetData.usageRows(u, now)[0].label)
        assertEquals("Codex · week", WidgetData.usageRows(u, now)[1].label)
    }

    @Test fun eachPlanUsesItsFiveHoursBeforeItsWeek() {
        val u = UsageSnapshot(PlanUsage(null, PlanWindow(30, later)), PlanUsage(five(55), PlanWindow(70, later)))
        assertEquals(listOf(UsageRing("Claude", "week", 30), UsageRing("Codex", "5 h", 55)), WidgetData.usageRows(u, now))
    }

    @Test fun onePlanOneRow() {
        assertEquals(listOf(UsageRing("Claude", "5 h", 20)), WidgetData.usageRows(UsageSnapshot(PlanUsage(five(20), null), null), now))
        assertEquals(listOf(UsageRing("Codex", "5 h", 20)), WidgetData.usageRows(UsageSnapshot(null, PlanUsage(five(20), null)), now))
    }

    @Test fun neverMoreThanTwoRows() {
        val u = UsageSnapshot(PlanUsage(five(1), PlanWindow(2, later)), PlanUsage(five(3), PlanWindow(4, later)))
        assertEquals(2, WidgetData.usageRows(u, now).size)
    }

    @Test fun nothingSentMeansNoRow() {
        assertTrue(WidgetData.usageRows(null, now).isEmpty())
        assertTrue(WidgetData.usageRows(UsageSnapshot(null, null), now).isEmpty())
        assertTrue(WidgetData.usageRows(UsageSnapshot(PlanUsage(null, null), PlanUsage(null, null)), now).isEmpty())
    }

    @Test fun aWindowThatHasResetCountsAsZero() {
        val u = UsageSnapshot(PlanUsage(five(80, reset = now - 1), null), null)
        assertEquals(0, WidgetData.usageRows(u, now).single().pct)
    }

    // ── The three things the right side shows ───────────────────────────────────────────────────────

    @Test fun notConnectedBeatsEverything() {
        val u = UsageSnapshot(PlanUsage(five(50), null), null)
        val c = build(u, LinkState.DISCONNECTED)
        assertEquals(UsageSide.NOT_CONNECTED, c.usageSide)
        assertTrue("nothing stale is shown", c.usageRows.isEmpty())
        assertEquals(UsageSide.NOT_CONNECTED, build(null, LinkState.CONNECTING).usageSide)
    }

    @Test fun connectedWithNoUsageSaysItIsOff() {
        assertEquals(UsageSide.OFF, build(null).usageSide)
        assertEquals(UsageSide.OFF, build(UsageSnapshot(null, null)).usageSide)
        assertEquals(UsageSide.OFF, build(UsageSnapshot(PlanUsage(null, null), null)).usageSide)
    }

    @Test fun connectedWithUsageShowsTheRows() {
        val c = build(UsageSnapshot(PlanUsage(five(68), null), PlanUsage(null, PlanWindow(41, later))))
        assertEquals(UsageSide.ROWS, c.usageSide)
        assertEquals(listOf(68, 41), c.usageRows.map { it.pct })
    }

    @Test fun everyStateHasASide() {
        // Whatever the content, the right side is one of the three: never nothing.
        for (link in LinkState.values()) for (u in listOf(null, UsageSnapshot(null, null), UsageSnapshot(PlanUsage(five(10), null), null))) {
            assertTrue(build(u, link).usageSide in UsageSide.values())
        }
    }

    @Test fun aChangeOfPercentageIsAChangeOfContent() {
        val a = build(UsageSnapshot(PlanUsage(five(68), null), null))
        assertFalse(a == build(UsageSnapshot(PlanUsage(five(69), null), null)))
        assertEquals(a, build(UsageSnapshot(PlanUsage(five(68), null), null)))
    }

    // ── The samples ─────────────────────────────────────────────────────────────────────────────────

    @Test fun theSamplesShowEachSide() {
        val working = WidgetData.sample(WidgetSample.WORKING, now)
        assertEquals(UsageSide.ROWS, working.usageSide)
        assertEquals(listOf("Claude · 5 h" to 42, "Codex · week" to 41), working.usageRows.map { it.label to it.pct })
        assertEquals(listOf(UsageTone.CALM, UsageTone.CALM), working.usageRows.map { it.tone })
        val waiting = WidgetData.sample(WidgetSample.WAITING, now)
        assertEquals(listOf(UsageTone.CLOSE, UsageTone.LIMIT), waiting.usageRows.map { it.tone })
        // The second row is at the limit: it says so, and when it resets.
        assertEquals("Near limit · " + PlanUsageLook.resetLine(now + 3 * 24 * 3_600_000L, now), waiting.usageRows[1].note)
        assertEquals("no warning below the red line", null, waiting.usageRows[0].note)
        assertEquals(UsageSide.ROWS, WidgetData.sample(WidgetSample.DONE, now).usageSide)
        assertEquals(1, WidgetData.sample(WidgetSample.DONE, now).usageRows.size)
        assertEquals(UsageSide.OFF, WidgetData.sample(WidgetSample.EMPTY, now).usageSide)
        assertEquals(UsageSide.NOT_CONNECTED, WidgetData.sample(WidgetSample.DISCONNECTED, now).usageSide)
    }
}
