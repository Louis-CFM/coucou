package com.coucou.android

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Source guards for the Solo and List widgets (Compose and Android classes only compile in CI), in the style of [GlanceSurfacesTest]. */
class WidgetSurfacesTest {
    private val main = "src/main/kotlin/com/coucou/android/"
    private fun read(path: String) = File(path).readText()
    private val manifest get() = read("src/main/AndroidManifest.xml")

    /** Every widget source: the providers, the hub, the pictures, the pure logic and the day's count. */
    private val widgets = listOf(
        "SoloWidget" to "coucou_solo_widget_info", "ListWidget" to "coucou_list_widget_info", "MochiBigWidget" to "coucou_big_widget_info",
        "StatusPillWidget" to "coucou_pill_widget_info", "WaitingAlertWidget" to "coucou_alert_widget_info",
        "UsageRingWidget" to "coucou_ring_widget_info", "TodayWidget" to "coucou_today_widget_info", "MoodWidget" to "coucou_mood_widget_info",
        // The summary widget (3x2): same class, receiver and provider file as ever, in the shared look since Widgets C.
        "GlanceWidget" to "coucou_widget_info",
    )
    private val sources = (
        widgets.map { "app/${it.first}.kt" } +
            listOf("app/WidgetHub.kt", "app/MochiBitmap.kt", "app/RingBitmap.kt", "app/BarBitmap.kt", "app/TodayStore.kt", "core/WidgetData.kt", "core/TodayCounter.kt", "core/LaunchScreen.kt")
        ).associateWith { read(main + it) }

    @Test fun theWidgetsAreRegisteredAndNeverWakeOnATimer() {
        for ((cls, info) in widgets) {
            assertTrue(manifest.contains("""android:name=".app.$cls""""))
            assertTrue(manifest.contains("@xml/$info"))
            val xml = read("src/main/res/xml/$info.xml")
            assertTrue(xml.contains("""android:updatePeriodMillis="0""""))
            assertTrue(xml.contains("""android:widgetCategory="home_screen""""))
        }
    }

    @Test fun noWidgetSourceTouchesAnythingBeyondTheGlance() {
        // Agent names, state words and colours only: no step text, no command, no file, no answer.
        for ((name, src) in sources) {
            for (word in listOf("statusText", "finalLine", "steps", ".command", "files", "project")) assertFalse("$name uses $word", src.contains(word))
        }
    }

    @Test fun noWidgetCanDecideAnything() {
        for ((name, src) in sources) {
            for (word in listOf("decide", "allow", "deny", "approve", "answer", "unpair")) assertFalse("$name uses $word", src.contains(word, ignoreCase = true))
        }
        for (layout in listOf("widget_solo", "widget_list")) assertFalse(read("src/main/res/layout/$layout.xml").contains("Button"))
    }

    @Test fun noTimerAndNoLibrary() {
        for ((name, src) in sources) {
            for (word in listOf("WorkManager", "postDelayed", "Handler(", "Timer", "androidx.glance")) assertFalse("$name uses $word", src.contains(word))
            if (name != "app/WidgetHub.kt") assertFalse("$name uses AlarmManager", src.contains("AlarmManager"))
        }
        // The one alarm: the Today widget at local midnight. Inexact and not waking the phone, so no exact-alarm permission and no wake-ups.
        val hub = sources.getValue("app/WidgetHub.kt")
        assertEquals(1, Regex("alarms\\.set\\(").findAll(hub).count())
        assertTrue(hub.contains("alarms.set(AlarmManager.RTC,"))
        for (word in listOf("RTC_WAKEUP", "setExact", "setAlarmClock", "setRepeating", "setInexactRepeating", "SCHEDULE_EXACT_ALARM", "USE_EXACT_ALARM")) {
            assertFalse(word, hub.contains(word))
            assertFalse("manifest asks for $word", manifest.contains(word))
        }
        assertFalse(read("build.gradle.kts").contains("androidx.glance"))
    }

    @Test fun everyPendingIntentIsImmutableAndExplicit() {
        val hub = sources.getValue("app/WidgetHub.kt")
        // Open the app, open a session, open a screen: three, all immutable, the last two through LaunchActivity.
        assertEquals(3, Regex("PendingIntent.getActivity").findAll(hub).count())
        // Plus the midnight alarm: one explicit, immutable broadcast to the Today widget.
        assertEquals(1, Regex("PendingIntent.getBroadcast").findAll(hub).count())
        assertTrue(hub.contains("Intent(ACTION_MIDNIGHT).setClass(context, TodayWidget::class.java)"))
        assertEquals(4, Regex("FLAG_IMMUTABLE").findAll(hub).count())
        assertEquals(2, Regex("Intent\\(context, LaunchActivity::class.java\\)").findAll(hub).count())
        assertTrue(hub.contains("Intent(context, MainActivity::class.java)"))
        for ((name, src) in sources) {
            if (name == "app/WidgetHub.kt") continue
            assertFalse("$name builds its own PendingIntent", src.contains("PendingIntent.get"))
            assertFalse("$name builds its own Intent", src.contains("Intent(\""))
        }
    }

    @Test fun everyRowAndEveryWidgetHasItsOwnRequestCode() {
        val hub = sources.getValue("app/WidgetHub.kt")
        val codes = Regex("""const val CODE_\w+ = (0x[0-9A-Fa-f]+)""").findAll(hub).map { it.groupValues[1] }.toList()
        assertEquals(15, codes.size)
        assertEquals(codes.size, codes.toSet().size)
        // The rows use CODE_LIST_ROW + index: the ranges must not run into the next code.
        val values = codes.map { it.removePrefix("0x").toInt(16) }.sorted()
        assertTrue(values.zipWithNext().all { (a, b) -> b - a >= 16 })
        assertTrue(sources.getValue("app/ListWidget.kt").contains("WidgetHub.CODE_LIST_ROW + i"))
        // Every provider uses its own code, and the family uses each code once.
        val used = widgets.map { (cls, _) -> Regex("""WidgetHub\.(CODE_\w+)""").findAll(sources.getValue("app/$cls.kt")).map { it.groupValues[1] }.toSet() }
        for (u in used) assertTrue(u.isNotEmpty())
        val flat = used.flatten()
        assertEquals("a code is shared by two Widgets: $flat", flat.size, flat.toSet().size)
    }

    @Test fun theImageAndTheBadgeAreDescribed() {
        assertTrue(sources.getValue("app/SoloWidget.kt").contains("setContentDescription(R.id.solo_mochi"))
        assertTrue(sources.getValue("app/SoloWidget.kt").contains("setContentDescription(R.id.solo_badge"))
        assertTrue(sources.getValue("app/ListWidget.kt").contains("setContentDescription(R.id.list_badge"))
        // Every Widget with a picture describes it; every layout image that is not decoration has a description or is hidden from it.
        for ((cls, _) in widgets) assertTrue("$cls has no content description", sources.getValue("app/$cls.kt").contains("setContentDescription("))
        for (layout in File("src/main/res/layout").listFiles()!!.filter { it.name.startsWith("widget_") }) {
            for (img in Regex("""<ImageView[^>]*>""").findAll(layout.readText())) {
                val tag = img.value
                assertTrue("${layout.name}: an image with neither a description nor importantForAccessibility=no: $tag",
                    tag.contains("android:contentDescription") || tag.contains("""android:importantForAccessibility="no""""))
            }
        }
    }

    @Test fun everyChangeOfThePictureReachesTheHub() {
        val model = read(main + "app/AppModel.kt")
        val push = model.substringAfter("private fun pushGlance()").substringBefore("private fun refreshIsland()")
        assertTrue(push.contains("WidgetHub.update"))
        assertTrue("the first widget stays", push.contains("GlanceWidget.update"))
        assertTrue(sources.getValue("app/WidgetHub.kt").contains("if (content == last) return"))
    }

    @Test fun theSummaryWidgetKeepsItsNamesAndItsRefreshPath() {
        // GlanceSurfacesTest guards its registration; this guards that the restyle kept the names, the size and the refresh path.
        assertTrue(manifest.contains("""android:name=".app.GlanceWidget""""))
        assertTrue(manifest.contains("@xml/coucou_widget_info"))
        assertTrue(File("src/main/res/layout/widget_glance.xml").exists())
        val info = read("src/main/res/xml/coucou_widget_info.xml")
        assertTrue(info.contains("""android:targetCellWidth="3""""))
        assertTrue(info.contains("""android:targetCellHeight="2""""))
        assertTrue(info.contains("""android:initialLayout="@layout/widget_glance""""))
        val src = read(main + "app/GlanceWidget.kt")
        assertTrue(src.contains("fun update(context: Context, glance: Glance)"))
        assertTrue(src.contains("model.glance()"))
        // Its data is the Glance's, and a tap anywhere opens the app: no button, no session, no screen.
        for (word in listOf("g.headline", "g.detail", "g.lines", "g.waiting")) assertTrue(word, src.contains(word))
        assertTrue(src.contains("WidgetHub.openApp("))
        for (word in listOf("openScreen", "openSession", "LaunchScreen")) assertFalse(word, src.contains(word))
        val layout = read("src/main/res/layout/widget_glance.xml")
        assertFalse(layout.contains("<Button"))
        assertFalse("no icon button in the summary", Regex("ic_widget_(home|chat|settings|recent|session|pair)").containsMatchIn(layout))
        assertTrue("it shows the not-connected icon", layout.contains("@drawable/ic_widget_offline"))
    }

    @Test fun theListRowsAreAtLeastFortyEightDpAndTheEmptyStateFillsTheCard() {
        val list = read("src/main/res/layout/widget_list.xml")
        assertEquals(5, Regex("""android:layout_height="@dimen/widget_row_min"""").findAll(list).count())
        for (id in listOf("list_empty", "list_empty_face", "list_empty_title", "list_empty_line", "list_tint", "list_root")) assertTrue(id, list.contains("@+id/$id"))
        val code = read(main + "app/ListWidget.kt")
        assertTrue(code.contains("c.tiles.isEmpty()"))
        assertTrue(code.contains("R.id.list_empty"))
    }

    @Test fun theCardsUseTheSharedLook() {
        for (layout in listOf("widget_solo", "widget_list", "widget_glance", "widget_pill", "widget_big")) {
            val xml = read("src/main/res/layout/$layout.xml")
            assertTrue(layout, xml.contains("@drawable/widget_card"))
            assertTrue(layout, xml.contains("@drawable/widget_tint_muted"))
            // Colours and sizes come from the shared resources, never from a literal grey at 12sp.
            assertFalse(layout, xml.contains("#FFAEAEB2"))
        }
        val solo = read(main + "app/SoloWidget.kt")
        assertTrue(solo.contains("WidgetHub.paint("))
        assertTrue(read(main + "app/ListWidget.kt").contains("WidgetHub.paint("))
    }

    @Test fun mochiHasAtLeastHalfOfTheSoloCard() {
        val solo = read("src/main/res/layout/widget_solo.xml")
        // Mochi takes the leftover height (weight 1) while the text rows wrap their content.
        assertTrue(solo.contains("""android:layout_weight="1""""))
        assertTrue(read(main + "app/SoloWidget.kt").contains("glow = true"))
    }

    // ── The debug preview: it must exist in debug builds and nowhere else ──────────────────────────

    @Test fun thePreviewReceiverLivesInTheDebugSourceSetOnly() {
        assertTrue(File("src/debug/kotlin/com/coucou/android/app/WidgetPreviewReceiver.kt").exists())
        val debugManifest = read("src/debug/AndroidManifest.xml")
        assertTrue(debugManifest.contains(".app.WidgetPreviewReceiver"))
        assertTrue(debugManifest.contains("com.coucou.android.debug.WIDGET_STATE"))
        // Not in the main source set, not in the manifest every build gets.
        assertFalse(File(main + "app/WidgetPreviewReceiver.kt").exists())
        assertFalse(manifest.contains("WidgetPreviewReceiver"))
        assertFalse(manifest.contains("com.coucou.android.debug"))
        assertFalse(File("src/release").exists() && File("src/release").walkTopDown().any { it.readText().contains("WidgetPreviewReceiver") })
        // Nothing in the main code calls it, and nothing outside the debug receiver pins a preview.
        for (f in File(main).walkTopDown().filter { it.extension == "kt" }) {
            val text = f.readText()
            assertFalse("${f.name} refers to the preview receiver", text.contains("WidgetPreviewReceiver") && f.name != "WidgetHub.kt")
            if (f.name != "WidgetHub.kt") assertFalse("${f.name} pins a preview", text.contains("WidgetHub.preview("))
        }
        assertTrue(read("build.gradle.kts").contains("""sourceSets["debug"]"""))
    }

    @Test fun thePreviewReceiverDocumentsEveryCommand() {
        val src = read("src/debug/kotlin/com/coucou/android/app/WidgetPreviewReceiver.kt")
        for (state in listOf("disconnected", "empty", "working", "waiting", "done", "live")) {
            assertTrue(state, src.contains("--es state $state"))
        }
        assertTrue(src.contains("adb shell am broadcast -n com.coucou.android/.app.WidgetPreviewReceiver -a com.coucou.android.debug.WIDGET_STATE"))
        assertTrue(src.contains("DEBUG BUILDS ONLY"))
        assertTrue(src.contains("--ei usage 92"))
        // It only redraws Widgets with a made-up state.
        assertTrue(src.contains("WidgetSample.parse"))
        for (word in listOf("PendingLaunch", "approve", "AppModel", "SecureStore")) assertFalse(word, src.contains(word))
    }

    @Test fun aPreviewWaitsForNothingElseAndLiveGoesBack() {
        val hub = sources.getValue("app/WidgetHub.kt")
        assertTrue(hub.contains("fun preview(context: Context, content: WidgetContent?)"))
        assertTrue(hub.contains("pinned = content"))
        assertTrue(hub.contains("if (pinned != null && content != pinned) return"))
    }

    // ── Every Widget, at its smallest and at a large size ──────────────────────────────────────────

    private fun attr(xml: String, name: String) = Regex("""android:$name="([^"]*)"""").find(xml)?.groupValues?.get(1)
    private fun dp(v: String?) = v!!.removeSuffix("dp").toInt()

    @Test fun everyProviderDeclaresItsSizeAndIsListedWithAStringLabelAndDescription() {
        val strings = read("src/main/res/values/strings.xml")
        val expected = mapOf(
            "coucou_solo_widget_info" to (2 to 2), "coucou_list_widget_info" to (4 to 3), "coucou_big_widget_info" to (4 to 4),
            "coucou_pill_widget_info" to (4 to 1), "coucou_alert_widget_info" to (2 to 2), "coucou_ring_widget_info" to (2 to 2),
            "coucou_today_widget_info" to (2 to 2), "coucou_mood_widget_info" to (1 to 1), "coucou_widget_info" to (3 to 2),
        )
        assertEquals(widgets.map { it.second }.toSet(), expected.keys)
        for ((info, cells) in expected) {
            val xml = read("src/main/res/xml/$info.xml")
            assertEquals(info, cells.first, attr(xml, "targetCellWidth")!!.toInt())
            assertEquals(info, cells.second, attr(xml, "targetCellHeight")!!.toInt())
            // A cell is about 70dp less 30dp of margin: the minimum size is that of its cells.
            assertEquals(info, cells.first * 70 - 30, dp(attr(xml, "minWidth")))
            val high = dp(attr(xml, "minHeight"))
            // The List is a little taller than its three cells so that three rows fit; the others are exactly their cells.
            if (info.contains("list")) assertTrue(info, high >= cells.second * 70 - 30) else assertEquals(info, cells.second * 70 - 30, high)
            val desc = attr(xml, "description")!!.removePrefix("@string/")
            assertTrue("$info: $desc is not a string", strings.contains("""name="$desc""""))
            assertTrue(xml.contains("""android:initialLayout="@layout/widget_"""))
            // Never smaller than it can be drawn: a resize may not go below the minimum.
            attr(xml, "minResizeWidth")?.let { assertTrue(info, dp(it) <= dp(attr(xml, "minWidth"))) }
        }
        for ((cls, _) in widgets) {
            val label = Regex("""android:name="\.app\.$cls"[^>]*android:label="@string/(\w+)"""").find(manifest)!!.groupValues[1]
            assertTrue("$cls label $label", strings.contains("""name="$label""""))
        }
    }

    @Test fun theListNeverGoesBelowTwoRowsAndTheBigOneKeepsItsBubble() {
        val list = read("src/main/res/xml/coucou_list_widget_info.xml")
        // Header 28 + padding 20 + two rows of 48 = 144dp.
        assertTrue(dp(attr(list, "minResizeHeight")) >= 144)
        assertTrue(dp(attr(list, "minHeight")) >= 28 + 20 + 3 * 48)
        val big = read("src/main/res/xml/coucou_big_widget_info.xml")
        assertTrue(dp(attr(big, "minResizeHeight")) >= 180)
        val pill = read("src/main/res/xml/coucou_pill_widget_info.xml")
        assertEquals("horizontal", attr(pill, "resizeMode"))
        assertEquals("none", attr(read("src/main/res/xml/coucou_mood_widget_info.xml"), "resizeMode"))
    }

    @Test fun everyWidgetIsOnTheSharedCardAndOnlyUsesWhatRemoteViewsAllow() {
        val allowed = setOf("FrameLayout", "LinearLayout", "RelativeLayout", "GridLayout", "TextView", "ImageView", "ProgressBar", "Button")
        for (layout in File("src/main/res/layout").listFiles()!!.filter { it.name.startsWith("widget_") }) {
            val xml = layout.readText()
            assertTrue(layout.name, xml.contains("@drawable/widget_card"))
            // A real layout starts muted and is repainted by WidgetHub; a preview is already in the tone of its sample.
            if (layout.name.startsWith("widget_preview_")) assertTrue(layout.name, xml.contains("@drawable/widget_tint_"))
            else assertTrue(layout.name, xml.contains("@drawable/widget_tint_muted"))
            for (tag in Regex("""<(\w+)[\s>]""").findAll(xml).map { it.groupValues[1] }) assertTrue("${layout.name}: <$tag> in a RemoteViews layout", tag in allowed)
            // Colours come from the shared resources (so the light variant follows the system), not from a literal.
            assertFalse(layout.name, Regex("""android:textColor="#(?!FF1C1C1E)""").containsMatchIn(xml))
        }
    }

    @Test fun theNamesOfTheWidgetsAreWidgetsEverywhere() {
        val strings = File("../i18n/app-strings.json").readText()
        val texts = listOf(strings, File("../README.md").readText(), File("../../docs/android.html").readText()).joinToString("\n")
        assertFalse(texts.contains("Wedge", ignoreCase = true))
        // The picker names: short, and the same ones in the README.
        val readme = File("../README.md").readText()
        for (w in listOf("Mochi at a glance", "All your agents", "Mochi, big", "One-line status", "Approvals waiting", "Plan usage", "Finished today", "Mochi's mood")) {
            assertTrue(w, strings.contains(w))
            assertTrue("$w is not in the README", readme.contains(w))
        }
    }
}
