package com.coucou.android

import com.coucou.android.core.Glance
import com.coucou.android.core.GlanceTone
import com.coucou.android.core.GlanceLine
import com.coucou.android.core.look
import com.coucou.android.core.mood
import com.coucou.android.core.WidgetContent
import com.coucou.android.core.WidgetTile
import com.coucou.android.core.WidgetTone
import com.coucou.android.mochi.BotState
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Widgets' state palette: the pure mapping, and that the colour resources say the same thing. */
class WidgetToneTest {
    private fun colours(path: String): Map<String, String> =
        Regex("""<color name="(\w+)">(#[0-9A-Fa-f]{6,8})</color>""").findAll(File(path).readText()).associate { it.groupValues[1] to it.groupValues[2] }

    private val dark get() = colours("src/main/res/values/colors.xml")
    private val light get() = colours("src/main/res/values-notnight/colors.xml")

    private fun content(connected: Boolean = true, waiting: Int = 0, vararg states: BotState) = WidgetContent(
        "x", GlanceTone.CALM, connected, waiting, states.mapIndexed { i, s -> WidgetTile("p$i", "n$i", s, "w", 0xFF000000.toInt()) },
    )

    @Test fun everyStateHasATone() {
        for (s in BotState.values()) WidgetTone.of(s)
        assertEquals(WidgetTone.ATTENTION, WidgetTone.of(BotState.APPROVAL))
        assertEquals(WidgetTone.ATTENTION, WidgetTone.of(BotState.QUESTION))
        for (s in listOf(BotState.WORKING, BotState.THINKING, BotState.SEARCHING)) assertEquals(WidgetTone.WORKING, WidgetTone.of(s))
        assertEquals(WidgetTone.DONE, WidgetTone.of(BotState.FINISHED))
        for (s in listOf(BotState.ERROR, BotState.RATELIMIT, BotState.DIZZY)) assertEquals(WidgetTone.TROUBLE, WidgetTone.of(s))
        for (s in listOf(BotState.IDLE, BotState.SLEEPING)) assertEquals("calm is soft grey, not the muted grey of 'not connected'", WidgetTone.IDLE, WidgetTone.of(s))
    }

    @Test fun aComputerThatIsNotConnectedIsAlwaysMuted() {
        for (s in BotState.values()) assertEquals(WidgetTone.MUTED, WidgetTone.of(s, connected = false))
    }

    @Test fun theColoursAreOpaqueAndTheOnesOfMochi() {
        assertEquals(0xFFF5A524.toInt(), WidgetTone.ATTENTION.argb)
        assertEquals(0xFF3B9EFF.toInt(), WidgetTone.WORKING.argb)
        assertEquals(0xFF34D499.toInt(), WidgetTone.DONE.argb)
        assertEquals(0xFFF4505E.toInt(), WidgetTone.TROUBLE.argb)
        assertEquals(0xFF94A2B8.toInt(), WidgetTone.MUTED.argb)
        assertEquals(0xFFB8BDC7.toInt(), WidgetTone.IDLE.argb)
    }

    @Test fun theResourcesCarryTheSamePalette() {
        for (t in WidgetTone.values()) {
            val hex = dark.getValue("widget_tone_${t.name.lowercase()}").removePrefix("#")
            assertEquals(t.name, t.argb.toUInt().toString(16).uppercase().padStart(8, '0'), hex.uppercase())
            assertFalse("the tone colours are the same in day mode", light.containsKey("widget_tone_${t.name.lowercase()}"))
        }
    }

    @Test fun theGradientIsTheToneAtFifteenToTwentyFivePercent() {
        for (t in WidgetTone.values()) {
            val tint = dark.getValue("widget_tint_${t.name.lowercase()}").removePrefix("#")
            assertEquals(8, tint.length)
            val alpha = tint.substring(0, 2).toInt(16) / 255.0
            assertTrue("${t.name} alpha $alpha", alpha in 0.145..0.255)
            assertEquals(dark.getValue("widget_tone_${t.name.lowercase()}").removePrefix("#FF").uppercase(), tint.substring(2).uppercase())
        }
    }

    @Test fun theLightVariantRestylesTheCardAndTheText() {
        for (k in listOf("widget_card", "widget_border", "widget_text", "widget_text_soft", "widget_text_secondary")) {
            assertTrue(k, light.containsKey(k))
            assertTrue("$k differs in day mode", light[k] != dark[k])
        }
        // White at 85 % on the dark card, and 70 % for the secondary text.
        assertEquals("#D9FFFFFF", dark["widget_text_soft"])
        assertEquals("#B3FFFFFF", dark["widget_text_secondary"])
    }

    @Test fun theCardHasTwentyFourDpCornersAndABorder() {
        assertTrue(File("src/main/res/values/dimens.xml").readText().contains("""<dimen name="widget_radius">24dp</dimen>"""))
        assertTrue(File("src/main/res/values/dimens.xml").readText().contains("""<dimen name="widget_border_width">1dp</dimen>"""))
        val card = File("src/main/res/drawable/widget_card.xml").readText()
        assertTrue(card.contains("@dimen/widget_radius"))
        assertTrue(card.contains("<stroke"))
    }

    @Test fun theTypographyScale() {
        val d = File("src/main/res/values/dimens.xml").readText()
        assertTrue(d.contains("""<dimen name="widget_text_name">16sp</dimen>"""))
        assertTrue(d.contains("""<dimen name="widget_text_state">13sp</dimen>"""))
        assertTrue(d.contains("""<dimen name="widget_text_secondary">12sp</dimen>"""))
        assertTrue(d.contains("""<dimen name="widget_text_note">14sp</dimen>"""))
        assertTrue(d.contains("""<dimen name="widget_row_min">48dp</dimen>"""))
    }

    @Test fun theLookFollowsWhatWaitsThenTheTopAgent() {
        assertEquals(WidgetTone.MUTED, content(connected = false, waiting = 2, states = arrayOf(BotState.WORKING)).look)
        assertEquals(WidgetTone.ATTENTION, content(waiting = 1, states = arrayOf(BotState.WORKING)).look)
        assertEquals(WidgetTone.WORKING, content(states = arrayOf(BotState.WORKING, BotState.IDLE)).look)
        assertEquals(WidgetTone.DONE, content(states = arrayOf(BotState.FINISHED)).look)
        assertEquals("connected with nothing to list is calm", WidgetTone.IDLE, content().look)
    }

    // ── The summary widget: the existing Glance, in the shared look ──────────────────────────────────

    private fun glance(connected: Boolean, vararg states: BotState) =
        Glance("h", "d", GlanceTone.CALM, connected, states.map { GlanceLine("A", "t", it) }, 0)

    @Test fun theSummaryLooksLikeEveryOtherWidgetForTheSameAgents() {
        assertEquals(WidgetTone.MUTED, glance(false, BotState.WORKING).look())
        assertEquals(WidgetTone.IDLE, glance(true).look())
        assertEquals(WidgetTone.IDLE, glance(true, BotState.IDLE, BotState.SLEEPING).look())
        assertEquals(WidgetTone.DONE, glance(true, BotState.FINISHED, BotState.IDLE).look())
        assertEquals(WidgetTone.WORKING, glance(true, BotState.WORKING, BotState.FINISHED).look())
        assertEquals(WidgetTone.ATTENTION, glance(true, BotState.APPROVAL, BotState.WORKING).look())
        assertEquals(WidgetTone.TROUBLE, glance(true, BotState.ERROR, BotState.WORKING).look())
        // Something waiting wins even when its session is not the first line.
        assertEquals(WidgetTone.ATTENTION, Glance("h", "d", GlanceTone.ATTENTION, true, listOf(GlanceLine("A", "t", BotState.WORKING)), 1).look())
    }

    @Test fun mochiOnTheSummaryFollowsTheMostUrgentLine() {
        assertEquals(BotState.APPROVAL, glance(true, BotState.APPROVAL, BotState.WORKING).mood())
        assertEquals(BotState.WORKING, glance(true, BotState.WORKING).mood())
        assertEquals(BotState.IDLE, glance(true).mood())
        assertEquals(BotState.SLEEPING, glance(false).mood())
    }
}
