package com.coucou.android

import com.coucou.android.core.WidgetTone
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What the Widget picker shows: every provider has a preview that exists, looks like the Widget with sample data, is static
 * (no ids, no runtime bitmap, nothing from the app) and has a short name and a one-line description.
 */
class WidgetPreviewTest {
    private val res = "src/main/res/"
    private fun read(path: String) = File(path).readText()
    private val strings: Map<String, String> =
        Regex("""<string name="(\w+)">(.*?)</string>""").findAll(read(res + "values/strings.xml")).associate { it.groupValues[1] to it.groupValues[2].replace("\\'", "'") }

    /** Provider XML name to the name of its preview. */
    private val providers = listOf("solo", "list", "big", "pill", "alert", "ring", "today", "mood", "glance")

    /** The provider file of a Widget: the summary widget keeps the name it has always had. */
    private fun infoName(name: String) = if (name == "glance") "coucou_widget_info" else "coucou_${name}_widget_info"
    private fun info(name: String) = read("${res}xml/${infoName(name)}.xml")
    private fun attr(xml: String, name: String) = Regex("""android:$name="([^"]*)"""").find(xml)?.groupValues?.get(1)
    private fun preview(name: String) = read("${res}layout/widget_preview_$name.xml")
    private val previewFiles get() = File(res + "layout").listFiles()!!.filter { it.name.startsWith("widget_preview_") }

    // ── Every provider points at a preview that exists ─────────────────────────────────────────────

    @Test fun everyProviderHasAPreviewLayoutAndAPreviewImageThatExist() {
        for (n in providers) {
            val xml = info(n)
            assertEquals("$n previewLayout", "@layout/widget_preview_$n", attr(xml, "previewLayout"))
            assertEquals("$n previewImage", "@drawable/widget_preview_image_$n", attr(xml, "previewImage"))
            assertTrue(File("${res}layout/widget_preview_$n.xml").exists())
            assertTrue(File("${res}drawable/widget_preview_image_$n.xml").exists())
            assertTrue("$n: the initial layout exists", File("${res}layout/" + attr(xml, "initialLayout")!!.removePrefix("@layout/") + ".xml").exists())
            // previewLayout is Android 12 and later; the app starts at Android 11, so lint is told it is deliberate.
            assertTrue("$n", xml.contains("""tools:targetApi="31""""))
        }
        assertEquals("one preview layout per provider, no stray ones", providers.map { "widget_preview_$it.xml" }.sorted(), previewFiles.map { it.name }.sorted())
    }

    @Test fun theSummaryWidgetKeepsItsNamesAndGainsAPreview() {
        val first = read(res + "xml/coucou_widget_info.xml")
        assertTrue(first.contains("""android:previewLayout="@layout/widget_preview_glance""""))
        assertTrue(first.contains("""android:initialLayout="@layout/widget_glance""""))
        assertTrue(first.contains("""android:updatePeriodMillis="0""""))
        assertTrue(read("src/main/AndroidManifest.xml").contains("""android:name=".app.GlanceWidget""""))
        assertTrue(File(res + "xml/coucou_widget_info.xml").exists())
    }

    // ── Names and descriptions ─────────────────────────────────────────────────────────────────────

    @Test fun everyLabelAndDescriptionIsShortClearAndOneLine() {
        val manifest = read("src/main/AndroidManifest.xml")
        val labels = mutableSetOf<String>()
        for (n in providers) {
            val desc = attr(info(n), "description")!!.removePrefix("@string/")
            val label = Regex("""android:name="\.app\.\w+"\s+android:exported="true"\s+android:label="@string/(\w+)"[^>]*>\s*<intent-filter>(?:(?!</receiver>).)*?${infoName(n)}""", RegexOption.DOT_MATCHES_ALL)
                .find(manifest)?.groupValues?.get(1)
            assertNotNull("$n has no label in the manifest", label)
            val l = strings.getValue(label!!)
            val d = strings.getValue(desc)
            assertTrue("$n label is empty", l.isNotBlank())
            assertTrue("$n description is empty", d.isNotBlank())
            assertTrue("$n label '$l' is long", l.length <= 24)
            assertTrue("$n description '$d' is long", d.length <= 60)
            assertFalse("$n description spans lines", d.contains("\n") || d.contains("\\n"))
            assertTrue("$n description should end with a full stop", d.endsWith("."))
            assertFalse("$n label is the description", l == d)
            assertTrue("$n label says Coucou although the picker already shows the app", !l.startsWith("Coucou"))
            labels += l
        }
        assertEquals("two Widgets with the same name", providers.size, labels.size)
    }

    @Test fun theNamesAreTheOnesInTheBrief() {
        val expected = mapOf(
            "widget_solo_label" to "Mochi at a glance", "widget_list_label" to "All your agents", "widget_big_label" to "Mochi, big",
            "widget_pill_label" to "One-line status", "widget_alert_label" to "Approvals waiting", "widget_ring_label" to "Plan usage",
            "widget_today_label" to "Finished today", "widget_mood_label" to "Mochi's mood", "widget_glance_label" to "Agents summary",
        )
        for ((k, v) in expected) assertEquals(k, v, strings[k])
    }

    // ── The preview layouts are static, self-contained and clean ───────────────────────────────────

    @Test fun aPreviewHasNoIdAndNothingFromTheAppAtRuntime() {
        for (f in previewFiles) {
            val xml = f.readText()
            // An id is how the app finds a view to update: a preview has none, so nothing can be pushed into it.
            assertFalse("${f.name} has an id", Regex("""android:id=|@\+id/|@id/""").containsMatchIn(xml))
            for (tag in listOf("<include", "<merge", "<ViewStub", "<fragment", "<ListView", "<GridView")) assertFalse("${f.name} uses $tag", xml.contains(tag))
            // The root fills the cell the provider asks for, so the picker neither squashes nor crops it.
            val root = xml.substringAfter("<FrameLayout").substringBefore(">")
            assertTrue(f.name, root.contains("""android:layout_width="match_parent"""") && root.contains("""android:layout_height="match_parent""""))
        }
    }

    @Test fun aPreviewSaysNoCommandNoStepAndNoFile() {
        for (f in previewFiles) {
            val xml = f.readText()
            val text = xml + "\n" + Regex("""@string/(\w+)""").findAll(xml).joinToString("\n") { strings.getValue(it.groupValues[1]) }
            for (word in listOf("statusText", "steps", ".command", "files")) assertFalse("${f.name} says $word", text.contains(word))
        }
    }

    @Test fun aPreviewOnlyUsesVectorsAndTheSharedResources() {
        val allowed = setOf("FrameLayout", "LinearLayout", "TextView", "ImageView")
        for (f in previewFiles) {
            val xml = f.readText()
            for (tag in Regex("""<(\w+)[\s>]""").findAll(xml).map { it.groupValues[1] }) assertTrue("${f.name}: <$tag>", tag in allowed)
            // Every drawable it names is an XML drawable (vector, shape or layer list), never a bitmap.
            for (d in Regex("""@drawable/(\w+)""").findAll(xml).map { it.groupValues[1] }.toSet()) {
                assertTrue("${f.name}: @drawable/$d is not an XML drawable", File("${res}drawable/$d.xml").exists())
            }
            // The shared card and tone colours, not literals; the only literal colour is the dark text on the orange badge.
            assertFalse(f.name, Regex("""android:textColor="#(?!FF1C1C1E)""").containsMatchIn(xml))
            assertTrue(f.name, xml.contains("@drawable/widget_card"))
            assertTrue(f.name, xml.contains("@drawable/widget_tint_"))
            // Every image is described or hidden from accessibility (a still picture of a sample).
            for (img in Regex("""<ImageView[^>]*>""").findAll(xml)) assertTrue("${f.name}: $img", img.value.contains("importantForAccessibility=\"no\"") || img.value.contains("contentDescription"))
        }
    }

    @Test fun theSampleDataIsTheOneInTheBrief() {
        fun text(n: String) = Regex("""@string/(\w+)""").findAll(preview(n)).map { strings.getValue(it.groupValues[1]) }.toList()
        assertEquals(listOf("Claude Code", "Waiting for your approval", "1"), text("solo").filter { it in setOf("Claude Code", "Waiting for your approval", "1") })
        val list = text("list")
        assertEquals("Waiting for you", list.first())
        assertEquals(listOf("Waiting for you", "1", "Claude Code", "Waiting for your approval", "Codex", "Working", "Gemini CLI", "Finished"), list)
        assertEquals(3, Regex("""android:minHeight="@dimen/widget_row_min"""").findAll(preview("list")).count())
        // Mochi Big: Mochi, the agent and its state on the left; Claude 68% and Codex 41% on the right; the six tiles.
        assertEquals(
            listOf("Claude Code", "Working", "Claude · 5 h", "68%", "Codex · week", "41%", "Home", "Chat", "Settings", "Recent", "Top agent", "Pair again"),
            text("big"),
        )
        assertEquals(listOf("2 agents working", "Claude Code", "Working", "Codex", "Thinking", "Gemini CLI", "Idle"), text("glance"))
        assertEquals(listOf("Claude", "Working"), text("pill"))
        // The pill shows its four buttons: home, chat, settings and recent, in that order.
        assertEquals(listOf("ic_widget_home", "ic_widget_chat", "ic_widget_settings", "ic_widget_recent"), Regex("""@drawable/(ic_widget_\w+)""").findAll(preview("pill")).map { it.groupValues[1] }.toList())
        assertEquals(listOf("2 waiting", "Claude Code"), text("alert"))
        assertEquals(listOf("68%", "Claude · 5 h"), text("ring"))
        assertTrue(text("today").containsAll(listOf("5", "done today")))
        assertTrue("the Mood preview shows only a face", text("mood").isEmpty())
        // The tones of the samples: waiting orange, working blue, finished green.
        assertTrue(preview("solo").contains("widget_tone_attention") && preview("solo").contains("preview_mochi_waiting"))
        assertTrue(preview("pill").contains("widget_tone_working"))
        assertTrue(preview("alert").contains("widget_card_attention"))
        assertTrue(preview("big").contains("preview_mochi_working") && preview("big").contains("widget_tint_working"))
        assertEquals("six tiles", 6, Regex("""@drawable/widget_tile_bg"""").findAll(preview("big")).count())
        assertEquals("two thin bars", 2, Regex("""@drawable/preview_bar_calm"""").findAll(preview("big")).count())
        assertFalse("no speech bubble", preview("big").contains("bubble", ignoreCase = true))
        assertTrue(preview("glance").contains("preview_mochi_working") && preview("glance").contains("widget_tint_working"))
        assertTrue(preview("mood").contains("preview_mochi_done") && preview("today").contains("preview_mochi_done"))
        assertTrue(preview("list").let { it.contains("preview_face_waiting") && it.contains("preview_face_working") && it.contains("preview_face_done") })
        assertTrue(preview("ring").contains("preview_ring_68"))
    }

    @Test fun theBadgeAndTheAlertAreOrange() {
        for (n in listOf("solo", "list")) assertTrue(n, preview(n).contains("@drawable/widget_badge_bg"))
        // The badge is the waiting tone from the shared palette, not a literal of its own.
        assertTrue(File(res + "drawable/widget_badge_bg.xml").readText().contains("@color/widget_tone_attention"))
        assertTrue(preview("alert").contains("""android:textColor="@color/widget_tone_attention_text""""))
    }

    // ── The vector Mochi ───────────────────────────────────────────────────────────────────────────

    private val states = mapOf("working" to WidgetTone.WORKING, "waiting" to WidgetTone.ATTENTION, "done" to WidgetTone.DONE, "idle" to WidgetTone.MUTED)
    private fun hex(t: WidgetTone) = t.argb.toUInt().toString(16).uppercase().padStart(8, '0').substring(2)

    @Test fun everyStateHasAVectorFaceAGlowAndTheLayeredMochi() {
        for ((state, tone) in states) {
            val face = read("${res}drawable/preview_face_$state.xml")
            val glow = read("${res}drawable/preview_glow_$state.xml")
            val mochi = read("${res}drawable/preview_mochi_$state.xml")
            assertTrue(state, face.contains("<vector") && glow.contains("<vector"))
            // The glow is in the state's colour and fades to nothing, and sits behind the face.
            assertTrue("$state glow colour", glow.contains(hex(tone)))
            assertTrue("$state glow fades out", glow.contains("""android:type="radial"""") && Regex("""android:color="#00${hex(tone)}"""").containsMatchIn(glow))
            assertTrue(mochi.indexOf("preview_glow_$state") in 0 until mochi.indexOf("preview_face_$state"))
            // The body, its light gradient, the pink cheeks and two dark eyes.
            assertTrue(face.contains("#EDEDEF") && face.contains("#C4C5CA"))
            assertTrue(face.contains("#59FF7896"))
            assertTrue(state, Regex("""#1A1412""").findAll(face).count() >= 2)
            for (d in listOf(face, glow)) {
                assertTrue(d.contains("""android:viewportWidth="120"""") && d.contains("""android:viewportHeight="120""""))
            }
        }
    }

    @Test fun theBadgesAreTheOnesOfTheStates() {
        assertTrue("blue dots bubble", read(res + "drawable/preview_face_working.xml").let { it.contains("#3B9EFF") && Regex("""#FFFFFF" android:pathData="M25.5""").containsMatchIn(it) })
        assertTrue("orange bang", read(res + "drawable/preview_face_waiting.xml").let { it.contains("#F5A524\" android:pathData=\"M25.7") && it.contains("#FFFFFF") })
        assertTrue("green check", read(res + "drawable/preview_face_done.xml").let { it.contains("#34D499") && it.contains("""android:strokeColor="#FFFFFF"""") })
        assertFalse("calm: no badge", read(res + "drawable/preview_face_idle.xml").contains("""android:fillColor="#000000""""))
    }

    @Test fun theRingIsANormalTealArcAtSixtyEightPercent() {
        val ring = read(res + "drawable/preview_ring_68.xml")
        assertFalse(File(res + "drawable/preview_ring_70.xml").exists())
        assertTrue(ring.contains("""android:strokeLineCap="round""""))
        // Plan usage has its own palette: teal under 75%, never a state colour.
        assertTrue(ring.contains("#" + usageHex(com.coucou.android.core.UsageTone.CALM)))
        assertFalse(ring.contains("#" + hex(WidgetTone.ATTENTION)))
        // 68 % of the circle from the top, clockwise: it ends at 244.8 degrees (x = 50 + 44 sin, y = 50 - 44 cos).
        val end = Regex("""M50,6 A44,44 0 1 1 (?!50,)([\d.]+),([\d.]+)""").find(ring)!!.groupValues
        val deg = 0.68 * 360
        assertEquals(50 + 44 * Math.sin(Math.toRadians(deg)), end[1].toDouble(), 0.1)
        assertEquals(50 - 44 * Math.cos(Math.toRadians(deg)), end[2].toDouble(), 0.1)
        // A normal look under the red line: the ring's percentage is small and not bold.
        val layout = preview("ring")
        assertTrue(layout.contains("@dimen/widget_text_pct") && !layout.contains("android:textStyle=\"bold\""))
    }

    private fun usageHex(t: com.coucou.android.core.UsageTone) = t.argb.toUInt().toString(16).uppercase().padStart(8, '0').substring(2)

    @Test fun nothingInThePreviewsIsABitmap() {
        for (dir in File(res).listFiles()!!.filter { it.name.startsWith("drawable") || it.name.startsWith("mipmap") }) {
            for (f in dir.listFiles()!!.filter { it.name.startsWith("preview_") || it.name.startsWith("widget_preview_") }) {
                assertEquals("${f.path} is not an XML drawable", "xml", f.extension)
            }
        }
    }

    @Test fun theFallbackImageIsTheCardWithMochiInIt() {
        for (n in providers) {
            val d = read("${res}drawable/widget_preview_image_$n.xml")
            assertTrue(n, d.contains("<layer-list"))
            assertTrue(n, d.contains("@drawable/widget_card"))
            assertTrue(n, d.contains("@drawable/widget_tint_"))
            assertTrue(n, d.contains("@drawable/preview_"))
        }
    }

    // ── The initial layout is never a blank box ────────────────────────────────────────────────────

    @Test fun everyInitialLayoutShowsMochiOrAFaceAndAShortLineUntilTheFirstUpdate() {
        val real = mapOf("solo" to "solo", "list" to "list", "big" to "big", "pill" to "pill", "alert" to "alert", "ring" to "ring", "today" to "today", "mood" to "mood", "glance" to "glance")
        for ((n, layout) in real) {
            val xml = read("${res}layout/widget_$layout.xml")
            assertTrue("$n has no starting face", xml.contains("@drawable/preview_mochi_idle") || xml.contains("@drawable/preview_face_idle") || n == "pill")
            if (n != "mood") assertTrue("$n has no starting line", xml.contains("@string/widget_initial_"))
        }
        assertEquals("Coucou", strings["widget_initial_title"])
        assertEquals("Waiting for your agents", strings["widget_initial_line"])
        // The List starts on its empty state, not on empty rows.
        val list = read(res + "layout/widget_list.xml")
        assertTrue(Regex("""@\+id/list_header"[^>]*android:visibility="gone"""", RegexOption.DOT_MATCHES_ALL).containsMatchIn(list.substringBefore("@+id/list_status")))
    }

    @Test fun noWidgetLayoutSaysCommandStepOrFileEvenWithButtons() {
        val files = File(res + "layout").listFiles()!!.filter { it.name.startsWith("widget_") } + File(res + "drawable").listFiles()!!.filter { it.name.startsWith("ic_widget_") || it.name.startsWith("widget_") }
        for (f in files) {
            val xml = f.readText()
            val text = xml + "\n" + Regex("""@string/(\w+)""").findAll(xml).joinToString("\n") { strings.getValue(it.groupValues[1]) }
            for (word in listOf("statusText", "steps", ".command", "files")) assertFalse("${f.name} says $word", text.contains(word))
        }
        for (k in listOf("widget_btn_home", "widget_btn_chat", "widget_btn_settings", "widget_btn_recent", "widget_btn_session", "widget_btn_pair")) {
            for (word in listOf("statusText", "steps", ".command", "files")) assertFalse("$k says $word", strings.getValue(k).contains(word) && strings.getValue(k + "_cd").contains(word))
        }
    }

    // ── Nothing is cut in a preview ─────────────────────────────────────────────────────────────────

    /** A rough width in dp of one line of Roboto: about 0.5 em a character, 0.56 in bold. Good enough to catch a sentence that cannot fit. */
    private fun width(text: String, sp: Double, bold: Boolean) = text.length * sp * (if (bold) 0.56 else 0.50)
    private fun sample(key: String) = strings.getValue(key)

    @Test fun theStatusPillPreviewFitsTheWidthOfA4x1OnA720pxPhone() {
        // 720px at 2x is 360dp; a 4x1 there is about 330dp. Left of the four buttons (4 x 36 + 4 x 6) and the padding (16 + 8):
        val room = 330 - 16 - 8 - (4 * 36 + 4 * 6)
        val used = 10 + 8 + width(sample("widget_sample_claude_short"), 16.0, true) + 8 + width(sample("widget_sample_working"), 13.0, false)
        assertTrue("dot, name and state word need ${used.toInt()}dp of the $room dp there", used <= room)
        val xml = preview("pill")
        assertTrue(xml.contains("@string/widget_sample_claude_short") && xml.contains("@string/widget_sample_working"))
    }

    @Test fun theSummaryPreviewFitsItsHeadlineAndItsLinesInTheRightColumn() {
        // A 3x2 about 250dp wide: padding 12 + 12, Mochi 64 and 8 beside it.
        val room = 250 - 24 - 64 - 8
        assertTrue("headline ${width(sample("widget_sample_two_agents"), 16.0, true).toInt()}dp of $room", width(sample("widget_sample_two_agents"), 16.0, true) <= room)
        for ((name, state) in listOf("widget_sample_claude" to "widget_sample_working", "widget_sample_codex" to "widget_sample_thinking", "widget_sample_gemini" to "widget_sample_idle")) {
            val line = 8 + 6 + width(sample(name), 13.0, true) + 6 + width(sample(state), 12.0, false)
            assertTrue("$name line needs ${line.toInt()}dp of $room", line <= room)
        }
    }

    @Test fun theMochiBigPreviewFitsItsTwoSidesAtTheWidthOfA4x4() {
        // A 4x4 about 300dp wide: padding 12 + 12, so 276; Mochi's side is 45% of it, the usage side 55% less its 8dp margin.
        val left = 0.45 * (300 - 24)
        val right = 0.55 * (300 - 24) - 8
        val name = 10 + 6 + width(sample("widget_sample_claude"), 16.0, true)
        assertTrue("dot and name need ${name.toInt()}dp of ${left.toInt()}", name <= left)
        for (k in listOf("widget_sample_ring_label", "widget_sample_codex_week")) assertTrue(k, width(sample(k), 12.0, false) <= right)
        for (k in listOf("widget_sample_pct_a", "widget_sample_pct_b")) assertTrue(k, width(sample(k), 28.0, true) <= right)
    }
}
