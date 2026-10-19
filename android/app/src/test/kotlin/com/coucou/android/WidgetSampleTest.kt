package com.coucou.android

import com.coucou.android.core.UsageTone
import com.coucou.android.core.PlanUsageLook
import com.coucou.android.core.WidgetData
import com.coucou.android.core.WidgetSample
import com.coucou.android.core.WidgetTone
import com.coucou.android.mochi.BotState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The made-up states used to look at every Widget without a computer. Pure, so each one is pinned down here. */
class WidgetSampleTest {
    private val now = 5_000_000L
    private fun sample(s: WidgetSample) = WidgetData.sample(s, now)

    @Test fun disconnected() {
        val c = sample(WidgetSample.DISCONNECTED)
        assertFalse(c.connected)
        assertTrue(c.tiles.isEmpty())
        assertEquals(WidgetTone.MUTED, c.look)
        assertEquals("Waiting for your computer", c.emptyLine)
        assertEquals(BotState.SLEEPING, c.mood)
        assertEquals("Not connected", c.alertLine)
        assertNull(c.ring)
        assertEquals("Not connected", c.headline)
    }

    @Test fun empty() {
        val c = sample(WidgetSample.EMPTY)
        assertTrue(c.connected)
        assertTrue(c.tiles.isEmpty())
        assertEquals("No agents running", c.emptyLine)
        assertEquals(BotState.IDLE, c.mood)
        assertEquals("All calm", c.alertLine)
        assertNull("plan usage is off, so the ring asks for the switch", c.ring)
    }

    @Test fun working() {
        val c = sample(WidgetSample.WORKING)
        assertEquals(WidgetTone.WORKING, c.look)
        assertEquals("Claude Code", c.top!!.name)
        assertEquals(3, c.tiles.size)
        assertEquals(0, c.waiting)
        assertEquals("Claude", c.ring!!.plan)
        assertEquals(42, c.ring!!.pct)
        assertEquals(com.coucou.android.core.UsageTone.CALM, c.ring!!.tone)
        assertEquals(3, c.today)
    }

    @Test fun theUsageOverrideShowsTheNearLimitLook() {
        val now = 1_000_000L
        val c = WidgetData.sample(WidgetSample.WORKING, now, 92)
        assertEquals(92, c.ring?.pct)
        assertEquals(UsageTone.LIMIT, c.ring?.tone)
        assertEquals("Near limit · " + PlanUsageLook.resetLine(now + 2 * 3_600_000L, now), c.ring?.note)
        assertEquals(92, c.usageRows.first().pct)
        assertEquals("Claude", c.usageRows.first().plan)
        assertEquals(null, WidgetData.sample(WidgetSample.WORKING, now, 60).ring?.note)
        assertEquals(WidgetData.sample(WidgetSample.WORKING, now), WidgetData.sample(WidgetSample.WORKING, now, null))
        assertEquals(null, WidgetData.sample(WidgetSample.DISCONNECTED, now, 92).ring)
    }

    @Test fun theDisconnectedAlertFitsOneLine() {
        assertEquals("Waiting for your PC", sample(WidgetSample.DISCONNECTED).alertSub)
    }

    @Test fun waiting() {
        val c = sample(WidgetSample.WAITING)
        assertEquals(WidgetTone.ATTENTION, c.look)
        assertEquals(1, c.waiting)
        assertEquals("1 waiting", c.alertLine)
        assertEquals("Claude Code", c.alertSub)
        assertEquals(BotState.APPROVAL, c.mood)
        assertEquals("a request on top, then the others by urgency", listOf("Claude Code", "Codex", "Gemini CLI"), c.tiles.map { it.name })
        assertEquals(com.coucou.android.core.UsageTone.CLOSE, c.ring!!.tone)
    }

    @Test fun done() {
        val c = sample(WidgetSample.DONE)
        assertEquals(WidgetTone.DONE, c.look)
        assertEquals(5, c.today)
        assertEquals(BotState.FINISHED, c.todayMood)
        assertEquals(WidgetTone.DONE, c.todayLook)
        assertEquals(24, c.ring!!.pct)
    }

    @Test fun everyStateLooksDifferentAndHasSomethingToShow() {
        val all = WidgetSample.values().map { sample(it) }
        assertEquals(5, all.toSet().size)
        for (c in all) {
            assertTrue(c.headline.isNotBlank())
            assertTrue(c.alertLine.isNotBlank())
            assertTrue(c.alertSub.isNotBlank())
            assertTrue(c.tiles.size <= WidgetData.MAX_ROWS)
        }
        // The four tones that matter are all on show somewhere.
        assertEquals(setOf(WidgetTone.MUTED, WidgetTone.IDLE, WidgetTone.WORKING, WidgetTone.ATTENTION, WidgetTone.DONE), all.map { it.look }.toSet())
    }

    @Test fun theSamePreviewTwiceIsTheSameContentSoAPushCanBeSkipped() {
        for (s in WidgetSample.values()) assertEquals(sample(s), sample(s))
    }

    @Test fun theKeysAreWhatTheBroadcastSays() {
        assertEquals(listOf("disconnected", "empty", "working", "waiting", "done"), WidgetSample.values().map { it.key })
        assertEquals(WidgetSample.WAITING, WidgetSample.parse("waiting"))
        assertEquals(WidgetSample.WAITING, WidgetSample.parse("  Waiting "))
        assertEquals(WidgetSample.DONE, WidgetSample.parse("DONE"))
        for (bad in listOf(null, "", "live", "sleeping", "waiting now")) assertNull(bad, WidgetSample.parse(bad))
        assertNotNull(WidgetSample.parse("empty"))
    }
}
