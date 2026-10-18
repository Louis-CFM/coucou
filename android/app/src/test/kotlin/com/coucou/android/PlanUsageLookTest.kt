package com.coucou.android

import com.coucou.android.core.PlanUsageLook
import com.coucou.android.core.UsageRing
import com.coucou.android.core.UsageTone
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** One function decides how plan usage looks: its colour, whether it is shown prominently, and the "Near limit" line. */
class PlanUsageLookTest {
    private val now = 10_000_000L
    private val utc = java.time.ZoneOffset.UTC
    private fun inMinutes(m: Long) = now + m * 60_000

    @Test fun theThresholdsAreNamedConstants() {
        assertEquals(75, PlanUsageLook.CLOSE_FROM)
        assertEquals(90, PlanUsageLook.LIMIT_FROM)
        val src = File("src/main/kotlin/com/coucou/android/core/WidgetData.kt").readText()
        assertTrue(src.contains("const val CLOSE_FROM = 75") && src.contains("const val LIMIT_FROM = 90"))
    }

    @Test fun tealUnderSeventyFiveYellowFromSeventyFiveRedFromNinety() {
        for (p in listOf(0, 1, 50, 73, 74)) assertEquals("$p%", UsageTone.CALM, PlanUsageLook.tone(p))
        for (p in listOf(75, 76, 80, 89)) assertEquals("$p%", UsageTone.CLOSE, PlanUsageLook.tone(p))
        for (p in listOf(90, 91, 95, 100)) assertEquals("$p%", UsageTone.LIMIT, PlanUsageLook.tone(p))
    }

    @Test fun theExactBoundariesOfTheBrief() {
        assertEquals(UsageTone.CALM, PlanUsageLook.tone(74))
        assertEquals(UsageTone.CLOSE, PlanUsageLook.tone(75))
        assertEquals(UsageTone.CLOSE, PlanUsageLook.tone(89))
        assertEquals(UsageTone.LIMIT, PlanUsageLook.tone(90))
        assertEquals(UsageTone.LIMIT, PlanUsageLook.tone(100))
    }

    @Test fun valuesOutsideZeroToHundredAreClamped() {
        assertEquals(100, PlanUsageLook.clamp(140))
        assertEquals(100, PlanUsageLook.clamp(101))
        assertEquals(100, PlanUsageLook.clamp(Int.MAX_VALUE))
        assertEquals(0, PlanUsageLook.clamp(-1))
        assertEquals(0, PlanUsageLook.clamp(Int.MIN_VALUE))
        assertEquals(UsageTone.LIMIT, PlanUsageLook.tone(250))
        assertEquals(UsageTone.CALM, PlanUsageLook.tone(-40))
        val over = UsageRing("Claude", "5 h", 140)
        assertEquals(100, over.shown)
        assertEquals(1f, over.fraction, 0f)
        assertEquals(UsageTone.LIMIT, over.tone)
    }

    @Test fun onlyFromTheRedLineTheRateIsProminent() {
        for (p in listOf(0, 50, 74, 75, 89)) assertFalse("$p%", PlanUsageLook.nearLimit(p))
        for (p in listOf(90, 91, 100, 140)) assertTrue("$p%", PlanUsageLook.nearLimit(p))
        assertFalse(UsageRing("Claude", "5 h", 89).nearLimit)
        assertTrue(UsageRing("Claude", "5 h", 90).nearLimit)
    }

    @Test fun belowTheRedLineThereIsNoWarningLine() {
        for (p in listOf(0, 42, 74, 75, 89)) assertNull("$p%", PlanUsageLook.note(p, inMinutes(120), now, utc))
    }

    @Test fun fromTheRedLineItSaysNearLimitAndWhenItResets() {
        // 10,000,000 ms after the epoch is 02:46 UTC.
        assertEquals("Near limit · resets at 04:46", PlanUsageLook.note(90, inMinutes(120), now, utc))
        assertEquals("Near limit · resets at 04:51", PlanUsageLook.note(100, inMinutes(125), now, utc))
        assertEquals("Near limit · resets at 03:26", PlanUsageLook.note(95, inMinutes(40), now, utc))
        assertEquals("Near limit · resets Sun 02:46", PlanUsageLook.note(93, inMinutes(3 * 24 * 60), now, utc))
    }

    @Test fun withoutAResetTimeItJustSaysNearLimit() {
        assertEquals("Near limit", PlanUsageLook.note(95, 0L, now))
        assertEquals("a reset time in the past is no reset time", "Near limit", PlanUsageLook.note(95, now - 1, now))
    }

    @Test fun theResetLineIsAClockTimeThatStaysTrue() {
        assertEquals("resets at 02:47", PlanUsageLook.resetLine(inMinutes(1), now, utc))
        assertEquals("same day: just the time", "resets at 23:59", PlanUsageLook.resetLine(inMinutes(21 * 60 + 13), now, utc))
        assertEquals("next day: the day of the week", "resets Fri 00:00", PlanUsageLook.resetLine(inMinutes(21 * 60 + 14), now, utc))
        assertEquals("resets Wed 02:46", PlanUsageLook.resetLine(inMinutes(6 * 24 * 60), now, utc))
        assertEquals("a week or more: the date", "resets Jan 8 02:46", PlanUsageLook.resetLine(inMinutes(7 * 24 * 60), now, utc))
        assertNull(PlanUsageLook.resetLine(0L, now, utc))
        assertNull(PlanUsageLook.resetLine(now, now, utc))
    }

    @Test fun theClockTimeIsThePhonesOwn() {
        // The same moment reads differently in another time zone: 04:46 UTC is 10:16 in India.
        assertEquals("resets at 10:16", PlanUsageLook.resetLine(inMinutes(120), now, java.time.ZoneId.of("Asia/Kolkata")))
    }

    @Test fun theTextDoesNotChangeWhileTimePasses() {
        // Nothing redraws a Widget while the usage stays the same, so the line must not depend on "now".
        val at = inMinutes(120)
        assertEquals(PlanUsageLook.resetLine(at, now, utc), PlanUsageLook.resetLine(at, now + 60 * 60_000, utc))
    }

    @Test fun theRingAndTheTextComeFromTheSameFunction() {
        for (p in listOf(0, 74, 75, 89, 90, 100, 140)) {
            val row = UsageRing("Claude", "5 h", p, PlanUsageLook.note(p, inMinutes(120), now, utc))
            assertEquals(PlanUsageLook.tone(p), row.tone)
            assertEquals(PlanUsageLook.nearLimit(p), row.nearLimit)
            assertEquals("a note exactly when it is near the limit: $p%", row.nearLimit, row.note != null)
        }
    }

    // ── Its own palette ─────────────────────────────────────────────────────────────────────────────

    private val dark = Regex("""<color name="(\w+)">#([0-9A-Fa-f]{8})</color>""").findAll(File("src/main/res/values/colors.xml").readText()).associate { it.groupValues[1] to it.groupValues[2] }
    private fun hex(t: UsageTone) = t.argb.toUInt().toString(16).uppercase().padStart(8, '0')

    @Test fun theResourcesCarryTheSameUsagePalette() {
        for (t in UsageTone.values()) {
            val k = t.name.lowercase()
            assertEquals(k, hex(t), dark.getValue("widget_usage_$k").uppercase())
            assertEquals("tint $k", hex(t).substring(2), dark.getValue("widget_tint_usage_$k").substring(2).uppercase())
            assertEquals("border $k", "99" + hex(t).substring(2), dark.getValue("widget_border_usage_$k").uppercase())
            assertTrue("a card and a tint for $k", File("src/main/res/drawable/widget_card_usage_$k.xml").exists() && File("src/main/res/drawable/widget_tint_usage_$k.xml").exists())
        }
    }

    @Test fun theUsagePaletteNeverLooksLikeAState() {
        fun rgb(argb: Int) = intArrayOf((argb shr 16) and 255, (argb shr 8) and 255, argb and 255)
        fun dist(a: IntArray, b: IntArray) = Math.sqrt(a.indices.sumOf { ((a[it] - b[it]) * (a[it] - b[it])).toDouble() })
        for (u in UsageTone.values()) {
            for (s in com.coucou.android.core.WidgetTone.values()) {
                val d = dist(rgb(u.argb), rgb(s.argb))
                assertTrue("${u.name} is only ${d.toInt()} from ${s.name}", d >= 40.0)
            }
        }
        // And the three of them are clearly apart from each other, and the yellow is not the waiting orange.
        for (a in UsageTone.values()) for (b in UsageTone.values()) if (a != b) assertTrue("$a $b", dist(rgb(a.argb), rgb(b.argb)) >= 80.0)
        assertTrue(dist(rgb(UsageTone.CLOSE.argb), rgb(com.coucou.android.core.WidgetTone.ATTENTION.argb)) >= 40.0)
    }
}
