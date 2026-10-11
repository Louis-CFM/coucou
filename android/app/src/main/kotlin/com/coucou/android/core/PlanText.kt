package com.coucou.android.core

import com.coucou.android.link.PlanWindow
import java.time.Instant
import java.time.ZoneId
import java.time.format.TextStyle
import java.util.Locale

/**
 * How the plan usage reads on the phone, the same rules as the PC's pills (windows/src/core/plan.ts): a window
 * whose reset time has passed counts as 0, green under 50 %, orange up to 80 %, red above. Pure, so it is tested.
 */
object PlanText {
    enum class Level { LOW, MEDIUM, HIGH }

    /** What to show for a window: 0 once its reset time has passed. */
    fun effectivePct(w: PlanWindow, nowMs: Long): Int = if (w.resetsAtMs <= nowMs) 0 else w.pct

    fun level(pct: Int): Level = when {
        pct < 50 -> Level.LOW
        pct < 80 -> Level.MEDIUM
        else -> Level.HIGH
    }

    /** "in 1 h 20", "in 5 min", or "Resetting…" for a five-hour window. */
    fun resetsIn(w: PlanWindow, nowMs: Long): Reset {
        val secs = (w.resetsAtMs - nowMs) / 1000
        if (secs <= 0) return Reset.Now
        val hours = (secs / 3600).toInt()
        val mins = ((secs % 3600) / 60).toInt()
        return if (hours > 0) Reset.InHoursMinutes(hours, mins) else Reset.InMinutes(mins)
    }

    sealed interface Reset {
        data object Now : Reset
        data class InHoursMinutes(val h: Int, val m: Int) : Reset
        data class InMinutes(val m: Int) : Reset
    }

    /** "Mon 9:00" for the week's window, in the phone's own time zone. */
    fun weekday(w: PlanWindow, zone: ZoneId = ZoneId.systemDefault(), locale: Locale = Locale.getDefault()): String {
        val t = Instant.ofEpochMilli(w.resetsAtMs).atZone(zone)
        val day = t.dayOfWeek.getDisplayName(TextStyle.SHORT, locale)
        return "$day ${t.hour}:%02d".format(t.minute)
    }
}
