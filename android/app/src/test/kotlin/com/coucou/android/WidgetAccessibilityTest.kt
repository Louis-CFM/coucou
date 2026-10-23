package com.coucou.android

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

/** TalkBack: no Widget has a picture or a tapped area that is silent, and no spoken text is a raw engine key. */
class WidgetAccessibilityTest {
    private val main = "src/main/"
    private val ns = "http://schemas.android.com/apk/res/android"
    private val widgets = listOf(
        "SoloWidget", "ListWidget", "MochiBigWidget", "StatusPillWidget", "WaitingAlertWidget", "UsageRingWidget", "TodayWidget", "MoodWidget", "TeamWidget", "GlanceWidget",
    )

    private fun layouts() = File(main + "res/layout").listFiles { f -> f.name.startsWith("widget_") && !f.name.startsWith("widget_preview_") }!!.sortedBy { it.name }

    private fun elements(f: File): List<Element> {
        val doc = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }.newDocumentBuilder().parse(f)
        val all = doc.getElementsByTagName("*")
        return (0 until all.length).map { all.item(it) as Element }
    }

    @Test fun everyPictureInAWidgetLayoutIsDescribedOrSilent() {
        for (f in layouts()) for (e in elements(f)) {
            if (e.tagName != "ImageView") continue
            val described = e.getAttributeNS(ns, "contentDescription").isNotEmpty()
            val silent = e.getAttributeNS(ns, "importantForAccessibility") == "no"
            assertTrue("${f.name} ${e.getAttributeNS(ns, "id")} is neither described nor marked unimportant", described || silent)
        }
    }

    @Test fun everyTappedAreaIsDescribedByLayoutOrCode() {
        for (name in widgets) {
            val src = File(main + "kotlin/com/coucou/android/app/$name.kt").readText()
            val layoutText = layouts().joinToString("\n") { it.readText() }
            // Areas named in the code; those in a loop (the buttons) are described in the layout, which the first test covers.
            val tapped = Regex("""setOnClickPendingIntent\(\s*R\.id\.(\w+),""").findAll(src).map { it.groupValues[1] }.toSet()
            for (id in tapped) {
                val byCode = src.contains("setContentDescription(R.id.$id,") || src.contains("setContentDescription($id,")
                val byLayout = layouts().any { f ->
                    elements(f).any { e -> e.getAttributeNS(ns, "id") == "@+id/$id" && e.getAttributeNS(ns, "contentDescription").isNotEmpty() }
                }
                assertTrue("$name taps $id without a spoken description", byCode || byLayout)
            }
        }
    }

    @Test fun theRoundButtonsOfThePillSpeakTheirAction() {
        val pill = elements(File(main + "res/layout/widget_pill.xml")).filter { it.getAttributeNS(ns, "id").startsWith("@+id/pill_btn") }
        assertTrue(pill.size >= 4)
        for (e in pill) assertTrue(e.getAttributeNS(ns, "id"), e.getAttributeNS(ns, "contentDescription").startsWith("@string/widget_btn_"))
    }

    @Test fun spokenTextIsWordsNotEngineKeys() {
        for (name in widgets) {
            val src = File(main + "kotlin/com/coucou/android/app/$name.kt").readText()
            assertFalse("$name speaks a raw key", Regex("""widget_mochi_description,\s*[\w.]*mood\.key""").containsMatchIn(src))
            assertFalse("$name speaks a raw key", Regex("""widget_mochi_description,\s*[\w.]*Mood\.key""").containsMatchIn(src))
        }
    }

    @Test fun theTappedCardsSpeakOneSentence() {
        for (name in listOf("SoloWidget", "ListWidget", "WaitingAlertWidget", "MoodWidget")) {
            assertTrue(name, File(main + "kotlin/com/coucou/android/app/$name.kt").readText().contains("WidgetSpoken."))
        }
        assertEquals(1, Regex("WidgetSpoken\\.alert").findAll(File(main + "kotlin/com/coucou/android/app/WaitingAlertWidget.kt").readText()).count())
    }
}
