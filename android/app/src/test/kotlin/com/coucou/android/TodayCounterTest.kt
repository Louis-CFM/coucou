package com.coucou.android

import com.coucou.android.core.TodayCounter
import com.coucou.android.core.TodayMidnight
import com.coucou.android.core.TodayStorage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class TodayCounterTest {
    private class Memory : TodayStorage {
        var saved: Pair<String, Int>? = null
        override fun load() = saved
        override fun save(day: String, count: Int) { saved = day to count }
    }

    private var day = "2026-10-13"
    private val storage = Memory()
    private val counter = TodayCounter(storage) { day }

    @Test fun startsAtZero() = assertEquals(0, counter.count())

    @Test fun countsUpDuringTheDay() {
        assertEquals(1, counter.increment())
        assertEquals(2, counter.increment())
        assertEquals(2, counter.count())
        assertEquals("2026-10-13" to 2, storage.saved)
    }

    @Test fun readsZeroAfterMidnightWithoutAnythingRunning() {
        counter.increment(); counter.increment()
        day = "2026-10-14"
        assertEquals(0, counter.count())
    }

    @Test fun theFirstTaskOfTheNewDayStartsAtOne() {
        repeat(3) { counter.increment() }
        day = "2026-10-14"
        assertEquals(1, counter.increment())
        assertEquals("2026-10-14" to 1, storage.saved)
    }

    @Test fun anOldDayNeverComesBack() {
        counter.increment()
        day = "2026-10-12"
        assertEquals("a day that is not today is not today", 0, counter.count())
    }

    @Test fun theMidnightAlarmIsSetForTheNextLocalMidnight() {
        val utc = java.time.ZoneOffset.UTC
        val noon = 12 * 3_600_000L // 12:00 on 1 January 1970
        assertEquals(24 * 3_600_000L, TodayMidnight.nextAfter(noon, utc))
        assertEquals("exactly at midnight, the next one", 48 * 3_600_000L, TodayMidnight.nextAfter(24 * 3_600_000L, utc))
        assertEquals(24 * 3_600_000L, TodayMidnight.nextAfter(24 * 3_600_000L - 1, utc))
        // Local time, not UTC: in Kolkata (UTC+5:30) 12:00 UTC is 17:30, and the next midnight is 18:30 UTC.
        assertEquals(18 * 3_600_000L + 30 * 60_000L, TodayMidnight.nextAfter(noon, java.time.ZoneId.of("Asia/Kolkata")))
    }

    @Test fun onlyAPairedComputerCountsNotTheDemo() {
        val model = File("src/main/kotlin/com/coucou/android/app/AppModel.kt").readText()
        val line = model.lines().first { it.contains("todayCounter.increment()") }
        assertTrue("the demo loops every 20 s and must not add to the day", line.contains("mode == Mode.PAIRED"))
    }

    @Test fun midnightIsOurOwnAlarmBecauseTheSystemNoLongerSendsDateChanged() {
        val manifest = File("src/main/AndroidManifest.xml").readText()
        assertTrue(!manifest.contains("DATE_CHANGED"))
        assertTrue(manifest.contains("android.intent.action.TIME_SET") && manifest.contains("android.intent.action.TIMEZONE_CHANGED"))
        val widget = File("src/main/kotlin/com/coucou/android/app/TodayWidget.kt").readText()
        assertTrue(widget.contains("WidgetHub.scheduleMidnight") && widget.contains("onDisabled") && widget.contains("ACTION_MIDNIGHT"))
    }

    @Test fun itIsKeptOnThePhoneOnly() {
        val store = File("src/main/kotlin/com/coucou/android/app/TodayStore.kt")
        if (store.exists()) {
            val src = store.readText()
            assertTrue(src.contains("getSharedPreferences(\"widget_today\""))
            for (net in listOf("http", "Socket", "link.", "Protocol")) assertTrue(net, !src.contains(net))
        }
    }
}
