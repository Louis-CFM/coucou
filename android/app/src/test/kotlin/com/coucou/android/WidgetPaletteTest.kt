package com.coucou.android

import com.coucou.android.core.GlanceBuilder
import com.coucou.android.core.UsageTone
import com.coucou.android.core.WidgetData
import com.coucou.android.core.WidgetTone
import com.coucou.android.link.LinkState
import com.coucou.android.link.SessionInfo
import com.coucou.android.mochi.BotState
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** One palette for every Widget: the same state gives the same colour everywhere, nothing picks a colour of its own, and text stays readable. */
class WidgetPaletteTest {
    private val res = "src/main/res/"
    private val main = "src/main/kotlin/com/coucou/android/"
    private fun read(p: String) = File(p).readText()

    // ── One state, one colour, the most urgent agent wins ───────────────────────────────────────────

    private fun s(id: String, state: BotState) = SessionInfo(id, "", state, "", 0, 0, 0L)
    private fun look(link: LinkState, vararg states: BotState): WidgetTone {
        val sessions = states.mapIndexed { i, st -> s("p$i", st) }
        val g = GlanceBuilder.build(true, link, "PC", sessions, 0) { "x" }
        return WidgetData.build(g, sessions, { "x" }).look
    }

    @Test fun everyStateHasItsOneColour() {
        val expected = mapOf(
            BotState.FINISHED to WidgetTone.DONE,
            BotState.WORKING to WidgetTone.WORKING, BotState.THINKING to WidgetTone.WORKING, BotState.SEARCHING to WidgetTone.WORKING,
            BotState.APPROVAL to WidgetTone.ATTENTION, BotState.QUESTION to WidgetTone.ATTENTION,
            BotState.IDLE to WidgetTone.IDLE, BotState.SLEEPING to WidgetTone.IDLE,
            BotState.ERROR to WidgetTone.TROUBLE, BotState.RATELIMIT to WidgetTone.TROUBLE, BotState.DIZZY to WidgetTone.TROUBLE,
        )
        assertEquals("every state is mapped", BotState.values().toSet(), expected.keys)
        for ((st, tone) in expected) assertEquals(st.name, tone, WidgetTone.of(st))
    }

    @Test fun greenBlueOrangeGreyAndNotConnected() {
        assertEquals(WidgetTone.DONE, look(LinkState.CONNECTED, BotState.FINISHED))
        assertEquals(WidgetTone.WORKING, look(LinkState.CONNECTED, BotState.WORKING))
        assertEquals(WidgetTone.ATTENTION, look(LinkState.CONNECTED, BotState.APPROVAL))
        assertEquals(WidgetTone.ATTENTION, look(LinkState.CONNECTED, BotState.QUESTION))
        assertEquals("calm: soft grey", WidgetTone.IDLE, look(LinkState.CONNECTED))
        assertEquals(WidgetTone.IDLE, look(LinkState.CONNECTED, BotState.IDLE, BotState.SLEEPING))
        assertEquals("not connected: muted grey, whatever the agents were", WidgetTone.MUTED, look(LinkState.DISCONNECTED, BotState.WORKING))
        assertEquals(WidgetTone.MUTED, look(LinkState.CONNECTING))
        assertTrue("two different greys", WidgetTone.IDLE.argb != WidgetTone.MUTED.argb)
    }

    @Test fun theMostUrgentAgentSetsTheCard() {
        assertEquals(WidgetTone.ATTENTION, look(LinkState.CONNECTED, BotState.IDLE, BotState.FINISHED, BotState.WORKING, BotState.APPROVAL))
        assertEquals(WidgetTone.ATTENTION, look(LinkState.CONNECTED, BotState.WORKING, BotState.QUESTION))
        assertEquals(WidgetTone.WORKING, look(LinkState.CONNECTED, BotState.IDLE, BotState.FINISHED, BotState.WORKING))
        assertEquals(WidgetTone.WORKING, look(LinkState.CONNECTED, BotState.FINISHED, BotState.THINKING, BotState.IDLE))
        assertEquals(WidgetTone.DONE, look(LinkState.CONNECTED, BotState.IDLE, BotState.FINISHED))
        assertEquals(WidgetTone.IDLE, look(LinkState.CONNECTED, BotState.SLEEPING, BotState.IDLE))
        // A stopped agent (red) ranks above working in the existing order of core/Glance.kt, below something waiting.
        assertEquals(WidgetTone.TROUBLE, look(LinkState.CONNECTED, BotState.WORKING, BotState.ERROR))
        assertEquals(WidgetTone.ATTENTION, look(LinkState.CONNECTED, BotState.ERROR, BotState.APPROVAL))
    }

    @Test fun theOrderIsTheOneOfTheGlance() {
        val order = listOf(
            BotState.APPROVAL, BotState.QUESTION, BotState.ERROR, BotState.RATELIMIT, BotState.DIZZY,
            BotState.WORKING, BotState.SEARCHING, BotState.THINKING, BotState.FINISHED, BotState.SLEEPING, BotState.IDLE,
        )
        assertEquals(order, BotState.values().sortedBy { GlanceBuilder.rank(it) })
        val sessions = order.reversed().mapIndexed { i, st -> s("p$i", st) }
        val g = GlanceBuilder.build(true, LinkState.CONNECTED, "PC", sessions, 0) { "x" }
        val tiles = WidgetData.build(g, sessions, { "x" }).tiles
        assertEquals("the tiles come most urgent first", tiles.map { GlanceBuilder.rank(it.state) }, tiles.map { GlanceBuilder.rank(it.state) }.sorted())
    }

    @Test fun theTodayWidgetIsGreenOnceSomethingFinishedAndSoftGreyBefore() {
        val g = GlanceBuilder.build(true, LinkState.CONNECTED, "PC", emptyList(), 0) { "x" }
        assertEquals(WidgetTone.IDLE, WidgetData.build(g, emptyList(), { "x" }, today = 0).todayLook)
        assertEquals(WidgetTone.DONE, WidgetData.build(g, emptyList(), { "x" }, today = 1).todayLook)
    }

    // ── The palette in the resources ────────────────────────────────────────────────────────────────

    private fun colours(path: String) = Regex("""<color name="(\w+)">#([0-9A-Fa-f]{8})</color>""").findAll(read(path)).associate { it.groupValues[1] to it.groupValues[2].uppercase() }
    private val dark get() = colours(res + "values/colors.xml")
    private val light get() = dark + colours(res + "values-notnight/colors.xml")

    @Test fun everyToneHasItsColourItsTintItsBorderAndItsCard() {
        for (t in WidgetTone.values()) {
            val k = t.name.lowercase()
            val hex = t.argb.toUInt().toString(16).uppercase().padStart(8, '0')
            assertEquals(k, hex, dark.getValue("widget_tone_$k"))
            assertEquals("the border is the tone at 60%: $k", "99" + hex.substring(2), dark.getValue("widget_border_$k"))
            assertEquals("the tint is the tone: $k", hex.substring(2), dark.getValue("widget_tint_$k").substring(2))
            assertTrue("a card for $k", File("${res}drawable/widget_card_$k.xml").exists())
            assertTrue("a tint for $k", File("${res}drawable/widget_tint_$k.xml").exists())
            val card = read("${res}drawable/widget_card_$k.xml")
            assertTrue("$k: a 1dp border in the state's colour", card.contains("@dimen/widget_border_width") && card.contains("@color/widget_border_$k"))
        }
        assertTrue(read(res + "values/dimens.xml").contains("""<dimen name="widget_border_width">1dp</dimen>"""))
    }

    // ── Nothing picks a colour of its own ───────────────────────────────────────────────────────────

    @Test fun noWidgetLayoutHardCodesAColour() {
        for (f in File(res + "layout").listFiles()!!.filter { it.name.startsWith("widget_") }) {
            val hits = Regex(""""#[0-9A-Fa-f]{3,8}"""").findAll(f.readText()).map { it.value }.toList()
            assertTrue("${f.name} hard-codes $hits", hits.isEmpty())
        }
    }

    @Test fun noWidgetDrawableHardCodesAStateColour() {
        // A white base that code tints, and the transparent end of a gradient: nothing else.
        val allowed = setOf("#FFFFFFFF", "#00000000")
        for (f in File(res + "drawable").listFiles()!!.filter { (it.name.startsWith("widget_") || it.name.startsWith("ic_widget_")) && !it.name.startsWith("widget_preview_image_") }) {
            val hits = Regex("""#[0-9A-Fa-f]{6,8}""").findAll(f.readText()).map { it.value.uppercase() }.filter { it !in allowed }.toList()
            assertTrue("${f.name} hard-codes $hits", hits.isEmpty())
        }
        assertTrue(read(res + "drawable/widget_badge_bg.xml").contains("@color/widget_tone_attention"))
    }

    private val widgetSources = listOf(
        "SoloWidget", "ListWidget", "MochiBigWidget", "StatusPillWidget", "WaitingAlertWidget", "UsageRingWidget", "TodayWidget", "MoodWidget", "GlanceWidget",
    ).associateWith { read("${main}app/$it.kt") }

    @Test fun noWidgetSourceHardCodesAColour() {
        for ((name, src) in widgetSources + mapOf("WidgetHub" to read(main + "app/WidgetHub.kt"))) {
            assertFalse("$name has a hex colour", Regex("""0x[0-9A-Fa-f]{6,8}""").containsMatchIn(src))
            for (call in listOf("Color(", "Color.", "parseColor", "setTextColor(", "argb(")) assertFalse("$name uses $call", src.contains(call))
        }
        // The pictures keep only their neutral track and glow strength, named.
        for (f in listOf("BarBitmap", "RingBitmap", "MochiBitmap")) {
            for (line in read("${main}app/$f.kt").lines().filter { Regex("""0x[0-9A-Fa-f]{6,8}""").containsMatchIn(it) }) assertTrue("$f: $line", line.contains("TRACK"))
        }
    }

    @Test fun everyWidgetPaintsThroughTheHubAndNeverSetsItsOwnCard() {
        for ((name, src) in widgetSources) {
            assertTrue("$name does not paint through the hub", src.contains("WidgetHub.paint(") || src.contains("WidgetHub.paintUsage("))
            if (name != "MochiBigWidget") assertFalse("$name sets a background itself", src.contains("setBackgroundResource"))
        }
        // The plan-usage card uses the usage palette, and a Widget with no usage never borrows the orange.
        assertTrue(widgetSources.getValue("UsageRingWidget").contains("WidgetHub.paintUsage(v, R.id.ring_root, R.id.ring_tint, ring.tone)"))
        assertTrue(widgetSources.getValue("UsageRingWidget").contains("if (c.connected) WidgetTone.IDLE else WidgetTone.MUTED"))
    }

    @Test fun mochisGlowAlwaysFollowsTheCardsTone() {
        for ((name, src) in widgetSources) {
            for (line in src.lines().filter { it.contains("MochiBitmap.of(") && it.contains("glow = true") }) assertTrue("$name: $line", line.contains("tone ="))
        }
        val bitmap = read(main + "app/MochiBitmap.kt")
        assertTrue(bitmap.contains("tone: WidgetTone = WidgetTone.of(state)"))
        assertTrue(bitmap.contains("val tone: WidgetTone)"))
    }

    @Test fun theNotConnectedIconIsOnEveryWidgetThatShowsAStatus() {
        for ((name, layout) in listOf("SoloWidget" to "widget_solo", "ListWidget" to "widget_list", "MochiBigWidget" to "widget_big", "WaitingAlertWidget" to "widget_alert", "MoodWidget" to "widget_mood", "GlanceWidget" to "widget_glance")) {
            // In the layout, or set from code when the computer is not there (the List swaps its dot for it).
            assertTrue("$layout has no not-connected icon", read("${res}layout/$layout.xml").contains("@drawable/ic_widget_offline") || widgetSources.getValue(name).contains("R.drawable.ic_widget_offline"))
            assertTrue("$name never shows it", widgetSources.getValue(name).contains("connected"))
        }
        assertTrue(widgetSources.getValue("StatusPillWidget").contains("R.drawable.ic_widget_offline"))
        for (id in listOf("big_offline" to "MochiBigWidget", "alert_offline" to "WaitingAlertWidget", "mood_offline" to "MoodWidget", "glance_offline" to "GlanceWidget")) {
            assertTrue(id.first, widgetSources.getValue(id.second).contains("R.id.${id.first}"))
        }
    }

    @Test fun theButtonTilesAreOrangeOnlyWhileSomethingWaits() {
        val big = widgetSources.getValue("MochiBigWidget")
        assertTrue(big.contains("if (c.look == WidgetTone.ATTENTION) R.drawable.widget_tile_bg_attention else R.drawable.widget_tile_bg"))
        assertFalse("the pill's round buttons never turn orange", widgetSources.getValue("StatusPillWidget").contains("tile_bg"))
        assertTrue(read(res + "drawable/widget_tile_bg.xml").contains("@color/widget_button"))
        assertTrue(read(res + "drawable/widget_tile_bg_attention.xml").contains("@color/widget_tone_attention"))
    }

    // ── The picker previews keep their sample's colour ──────────────────────────────────────────────

    @Test fun eachPreviewKeepsItsSampleStateColour() {
        val sample = mapOf(
            "solo" to "attention", "list" to "attention", "big" to "working", "pill" to "working", "alert" to "attention",
            "today" to "done", "mood" to "done", "glance" to "working", "ring" to "usage_calm",
        )
        for ((n, tone) in sample) {
            val xml = read("${res}layout/widget_preview_$n.xml")
            assertTrue("$n card", xml.contains("""android:background="@drawable/widget_card_$tone""""))
            assertTrue("$n tint", xml.contains("""android:background="@drawable/widget_tint_$tone""""))
            val image = read("${res}drawable/widget_preview_image_$n.xml")
            assertTrue("$n Android 11 picture", image.contains("@drawable/widget_card_$tone") && image.contains("@drawable/widget_tint_$tone"))
        }
    }

    // ── Readable on every tinted card, in light and dark ────────────────────────────────────────────

    private fun argb(hex: String) = intArrayOf(hex.substring(0, 2).toInt(16), hex.substring(2, 4).toInt(16), hex.substring(4, 6).toInt(16), hex.substring(6, 8).toInt(16))
    private fun over(fg: IntArray, bg: IntArray): IntArray {
        val a = fg[0] / 255.0
        return intArrayOf(255, (fg[1] * a + bg[1] * (1 - a)).toInt(), (fg[2] * a + bg[2] * (1 - a)).toInt(), (fg[3] * a + bg[3] * (1 - a)).toInt())
    }
    private fun lum(c: IntArray): Double {
        fun f(v: Int): Double { val s = v / 255.0; return if (s <= 0.03928) s / 12.92 else Math.pow((s + 0.055) / 1.055, 2.4) }
        return 0.2126 * f(c[1]) + 0.7152 * f(c[2]) + 0.0722 * f(c[3])
    }
    private fun ratio(a: IntArray, b: IntArray): Double { val x = lum(a); val y = lum(b); return (maxOf(x, y) + 0.05) / (minOf(x, y) + 0.05) }

    @Test fun textIsReadableOnEveryTintedCardInLightAndDark() {
        val tints = WidgetTone.values().map { "widget_tint_${it.name.lowercase()}" } + UsageTone.values().map { "widget_tint_usage_${it.name.lowercase()}" }
        for ((mode, c) in listOf("dark" to dark, "light" to light)) {
            val card = argb(c.getValue("widget_card"))
            for (tint in tints) {
                // The gradient is strongest in its corner: take that, the worst case.
                val bg = over(argb(c.getValue(tint)), card)
                for ((name, need) in listOf("widget_text" to 7.0, "widget_text_soft" to 4.5, "widget_text_secondary" to 4.5)) {
                    val fg = over(argb(c.getValue(name)), bg)
                    val r = ratio(fg, bg)
                    assertTrue("$mode $name on $tint: ${"%.1f".format(r)}:1", r >= need)
                }
            }
        }
    }

    @Test fun theOrangeAlertCountIsReadableInLightAndDark() {
        for ((mode, c) in listOf("dark" to dark, "light" to light)) {
            val card = argb(c.getValue("widget_card"))
            val bg = over(argb(c.getValue("widget_tint_attention")), card)
            // 20sp bold is large text: 3:1 is the bar.
            val r = ratio(argb(c.getValue("widget_tone_attention_text")), bg)
            assertTrue("$mode: ${"%.1f".format(r)}:1", r >= 3.0)
        }
        // The badge: the dark text on the orange.
        val badge = ratio(argb(dark.getValue("widget_on_tone")), argb(dark.getValue("widget_tone_attention")))
        assertTrue("badge ${"%.1f".format(badge)}:1", badge >= 4.5)
    }
}
