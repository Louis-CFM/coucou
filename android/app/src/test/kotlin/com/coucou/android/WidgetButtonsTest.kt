package com.coucou.android

import com.coucou.android.core.LaunchScreen
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The buttons of the Status Pill and Mochi Big, and the room they take. A button only opens a screen of the app (or the top agent):
 * none approves, denies or sends anything, and each has its own request code, a name and a content description.
 */
class WidgetButtonsTest {
    private val main = "src/main/kotlin/com/coucou/android/"
    private val res = "src/main/res/"
    private fun read(path: String) = File(path).readText()
    private val strings: Map<String, String> =
        Regex("""<string name="(\w+)">(.*?)</string>""").findAll(read(res + "values/strings.xml")).associate { it.groupValues[1] to it.groupValues[2] }
    private val dimens: Map<String, Double> =
        Regex("""<dimen name="(\w+)">([\d.]+)(?:dp|sp)</dimen>""").findAll(read(res + "values/dimens.xml")).associate { it.groupValues[1] to it.groupValues[2].toDouble() }

    // A tiny reader for layout files: attributes keep their android: prefix (the parser is not namespace aware).
    private fun element(xml: String): org.w3c.dom.Element =
        javax.xml.parsers.DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(xml.byteInputStream()).documentElement
    private fun org.w3c.dom.Element.children(): List<org.w3c.dom.Element> =
        (0 until childNodes.length).map { childNodes.item(it) }.filterIsInstance<org.w3c.dom.Element>()
    private fun org.w3c.dom.Element.descendants(): List<org.w3c.dom.Element> = children().flatMap { listOf(it) + it.descendants() }

    // ── The icons ────────────────────────────────────────────────────────────────────────────────────

    private val icons = listOf("home", "chat", "settings", "recent", "session", "pair")

    @Test fun sixOutlineIconsWithOneStrokeWeight() {
        for (i in icons) {
            val xml = read("${res}drawable/ic_widget_$i.xml")
            assertTrue(i, xml.contains("<vector") && xml.contains("""android:width="24dp"""") && xml.contains("""android:viewportWidth="24""""))
            val widths = Regex("""android:strokeWidth="([\d.]+)"""").findAll(xml).map { it.groupValues[1] }.toSet()
            assertEquals("$i: one stroke weight", setOf("2"), widths)
            assertTrue("$i: in the Widgets' text colour, so the light variant follows", xml.contains("""android:strokeColor="@color/widget_text""""))
            assertFalse("$i: an outline, not a fill", xml.contains("android:fillColor"))
            assertTrue(i, xml.contains("""android:strokeLineCap="round""""))
        }
    }

    @Test fun theButtonsAreLighterCirclesAndRoundedTilesInBothModes() {
        val dark = read(res + "values/colors.xml")
        val light = read(res + "values-notnight/colors.xml")
        assertTrue(dark.contains("""<color name="widget_button">#1FFFFFFF</color>"""))
        assertTrue(light.contains("""<color name="widget_button">#14000000</color>"""))
        assertTrue(read(res + "drawable/widget_button_bg.xml").contains("""android:shape="oval""""))
        assertEquals(16.0, dimens.getValue("widget_tile_radius"), 0.0)
        assertTrue(read(res + "drawable/widget_tile_bg.xml").contains("@dimen/widget_tile_radius"))
        // Tinted orange while something waits.
        val waiting = read(res + "drawable/widget_tile_bg_attention.xml")
        assertTrue(waiting.contains("@color/widget_tint_attention") && waiting.contains("@color/widget_tone_attention"))
        assertTrue("round buttons of 36 to 40dp", dimens.getValue("widget_button") in 36.0..40.0)
    }

    @Test fun everyButtonHasAShortLabelAndADescription() {
        for (k in listOf("home", "chat", "settings", "recent", "session", "pair")) {
            val label = strings.getValue("widget_btn_$k")
            val cd = strings.getValue("widget_btn_${k}_cd")
            assertTrue("$k label '$label'", label.isNotBlank() && label.length <= 12)
            assertTrue("$k description '$cd'", cd.isNotBlank() && cd.length <= 40)
        }
    }

    // ── The Status Pill ─────────────────────────────────────────────────────────────────────────────

    @Test fun theStatusPillHasFourRoundButtonsThatOpenTheFourScreens() {
        val layout = read(res + "layout/widget_pill.xml")
        val ids = Regex("""@\+id/(pill_btn_\w+)""").findAll(layout).map { it.groupValues[1] }.toList()
        assertEquals(listOf("pill_btn_home", "pill_btn_chat", "pill_btn_settings", "pill_btn_recent"), ids)
        for (b in Regex("""<ImageView[^>]*pill_btn_[^>]*>""").findAll(layout)) {
            val tag = b.value
            assertTrue(tag, tag.contains("""android:layout_width="@dimen/widget_button"""") && tag.contains("""android:layout_height="@dimen/widget_button""""))
            assertTrue(tag, tag.contains("@drawable/widget_button_bg") && tag.contains("android:contentDescription=\"@string/widget_btn_"))
        }
        val src = read(main + "app/StatusPillWidget.kt")
        val pairs = Regex("""Button\(R\.id\.(pill_btn_\w+), LaunchScreen\.(\w+)\)""").findAll(src).map { it.groupValues[1] to it.groupValues[2] }.toList()
        assertEquals(listOf("pill_btn_home" to "HOME", "pill_btn_chat" to "CHAT", "pill_btn_settings" to "SETTINGS", "pill_btn_recent" to "RECENT"), pairs)
        assertTrue(src.contains("WidgetHub.openScreen(context, WidgetHub.CODE_PILL_BUTTON + i, b.screen)"))
        assertFalse("the pill opens no session from a button", src.contains("openSession(context, WidgetHub.CODE_PILL_BUTTON"))
    }

    @Test fun theStatusPillKeepsTheTextOffTheButtons() {
        val layout = read(res + "layout/widget_pill.xml")
        // The text group is the one weighted child of the row, so the buttons (fixed size) are measured first and never move.
        val row = element(layout).descendants().first { it.tagName == "LinearLayout" && it.getAttribute("android:orientation") == "horizontal" && it.children().any { c -> c.getAttribute("android:layout_weight").isNotEmpty() } }
        val weighted = row.children().filter { it.getAttribute("android:layout_weight").isNotEmpty() }
        assertEquals("exactly one weighted child: the text group", 1, weighted.size)
        val group = weighted.single()
        assertEquals("0dp", group.getAttribute("android:layout_width"))
        assertEquals("1", group.getAttribute("android:layout_weight"))
        assertEquals(listOf("LinearLayout"), listOf(group.tagName))
        val inside = group.descendants().mapNotNull { it.getAttribute("android:id").takeIf { id -> id.isNotEmpty() } }
        assertEquals(listOf("@+id/pill_dot", "@+id/pill_name", "@+id/pill_state"), inside)
        val others = row.children().filter { it !== group }
        assertEquals("the four buttons are the other children", listOf("@+id/pill_btn_home", "@+id/pill_btn_chat", "@+id/pill_btn_settings", "@+id/pill_btn_recent"), others.map { it.getAttribute("android:id") })
        for (b in others) {
            assertEquals(b.getAttribute("android:id"), "ImageView", b.tagName)
            assertEquals("a button has a fixed width", "@dimen/widget_button", b.getAttribute("android:layout_width"))
            assertTrue("a button has no weight, so it is never squeezed", b.getAttribute("android:layout_weight").isEmpty())
        }
        // The text inside the group: the state word is the weighted one (it shrinks first), the name wraps its content.
        val name = group.descendants().first { it.getAttribute("android:id") == "@+id/pill_name" }
        val state = group.descendants().first { it.getAttribute("android:id") == "@+id/pill_state" }
        assertEquals("wrap_content", name.getAttribute("android:layout_width"))
        assertEquals("0dp", state.getAttribute("android:layout_width"))
        assertEquals("1", state.getAttribute("android:layout_weight"))
        assertEquals("every text on the pill is one line, ellipsized", 2, Regex("""android:maxLines="1"""").findAll(layout).count())
        // Width budget in dp: padding 16 + 8, four buttons of 36 with 6 between.
        val buttons = 4 * dimens.getValue("widget_button") + 4 * 6 + 16 + 8
        val src = read(main + "app/StatusPillWidget.kt")
        val medium = Regex("""MEDIUM_AT = SizeF\((\d+)f""").find(src)!!.groupValues[1].toInt()
        val large = Regex("""LARGE_AT = SizeF\((\d+)f""").find(src)!!.groupValues[1].toInt()
        val minResize = Regex("""android:minResizeWidth="(\d+)dp"""").find(read(res + "xml/coucou_pill_widget_info.xml"))!!.groupValues[1].toInt()
        assertTrue("the buttons alone fit the narrowest the Widget can be", buttons <= minResize)
        assertTrue("from $medium dp the name has room (dot + about 80dp)", medium - buttons >= 90)
        assertTrue("from $large dp the state word has room too", large - buttons >= 90 + 50)
        assertTrue("narrower the pill hides the state word first: $medium < $large", medium < large)
        // Under the medium width only the dot is left of the buttons; the state word goes first, then the name.
        assertTrue(src.contains("R.id.pill_name, if (size == WidgetHub.Size.SMALL) View.GONE"))
        assertTrue(src.contains("R.id.pill_state, if (size == WidgetHub.Size.LARGE) View.VISIBLE else View.GONE"))
    }

    // ── Mochi Big ───────────────────────────────────────────────────────────────────────────────────

    private val bigLayout get() = read(res + "layout/widget_big.xml")
    private val bigSource get() = read(main + "app/MochiBigWidget.kt")
    private fun byId(root: org.w3c.dom.Element, id: String) = root.descendants().first { it.getAttribute("android:id") == "@+id/$id" }

    @Test fun theSpeechBubbleIsGoneFromEverywhere() {
        val files = listOf(
            res + "layout/widget_big.xml", res + "layout/widget_preview_big.xml", main + "app/MochiBigWidget.kt", main + "core/WidgetData.kt",
            res + "values/strings.xml", res + "values/colors.xml", res + "values-notnight/colors.xml", "../i18n/app-strings.json",
        )
        for (f in files) assertFalse("$f still says bubble", read(f).contains("bubble", ignoreCase = true))
        assertFalse(File(res + "drawable/widget_bubble.xml").exists())
        assertFalse(File(res + "drawable/widget_bubble_tail.xml").exists())
        assertFalse(strings.keys.any { it.contains("bubble") })
        for (id in listOf("big_bubble")) assertFalse(id, bigLayout.contains(id) || bigSource.contains(id))
        assertFalse(bigSource.contains(".bubble"))
        // And so are its sentences ("Claude Code is waiting for you").
        assertFalse(strings.values.any { it.contains("is waiting for you") || it.startsWith("Claude Code is ") })
    }

    @Test fun theTopIsMochiOnTheLeftAndThePlanUsageOnTheRight() {
        val root = element(bigLayout)
        val top = byId(root, "big_top")
        assertEquals("horizontal", top.getAttribute("android:orientation"))
        val sides = top.children()
        assertEquals(listOf("@+id/big_left", "@+id/big_right"), sides.map { it.getAttribute("android:id") })
        assertEquals("Mochi's side is about 45% of the width", listOf("45", "55"), sides.map { it.getAttribute("android:layout_weight") })
        val left = byId(root, "big_left").descendants().mapNotNull { it.getAttribute("android:id").takeIf { id -> id.isNotEmpty() } }
        assertEquals(listOf("@+id/big_mochi", "@+id/big_row", "@+id/big_offline", "@+id/big_dot", "@+id/big_name", "@+id/big_state"), left)
        assertEquals("the badge stays in the top-right corner", "top|end", byId(root, "big_badge").getAttribute("android:layout_gravity"))
    }

    @Test fun thePercentageAndTheBarExist() {
        val root = element(bigLayout)
        for (k in listOf("a", "b")) {
            val label = byId(root, "big_usage_${k}_label")
            val pct = byId(root, "big_usage_${k}_pct")
            val big = byId(root, "big_usage_${k}_pct_big")
            val note = byId(root, "big_usage_${k}_note")
            val bar = byId(root, "big_usage_${k}_bar")
            assertEquals("12sp label", "@dimen/widget_text_secondary", label.getAttribute("android:textSize"))
            // Under the red line: small and normal, no warning line. From the red line: big and bold, with the line under it.
            assertEquals("@dimen/widget_text_pct", pct.getAttribute("android:textSize"))
            assertTrue("the small percentage is not bold", pct.getAttribute("android:textStyle").isEmpty())
            assertEquals("@dimen/widget_text_pct_big", big.getAttribute("android:textSize"))
            assertEquals("bold", big.getAttribute("android:textStyle"))
            assertEquals("gone", big.getAttribute("android:visibility"))
            assertEquals("gone", note.getAttribute("android:visibility"))
            assertEquals("ImageView", bar.tagName)
            assertEquals("6dp", bar.getAttribute("android:layout_height"))
        }
        assertEquals(18.0, dimens.getValue("widget_text_pct"), 0.0)
        assertEquals(32.0, dimens.getValue("widget_text_pct_big"), 0.0)
        assertEquals(12.0, dimens.getValue("widget_text_secondary"), 0.0)
        assertFalse("the old 28sp bold percentage is gone", dimens.containsKey("widget_text_big"))
        // The code puts the percentage and a bar bitmap in each row, and Claude and Codex are the two rows.
        assertTrue(bigSource.contains("""v.setTextViewText(if (near) r.pctBig else r.pct, "${'$'}{row.shown}%")"""))
        assertTrue(bigSource.contains("val near = row.nearLimit"))
        assertTrue(bigSource.contains("BarBitmap.of(row,"))
        assertTrue(bigSource.contains("R.id.big_usage_a_bar") && bigSource.contains("R.id.big_usage_b_bar"))
        assertTrue(File(main + "app/BarBitmap.kt").readText().contains("row.tone"))
    }

    @Test fun thePlanUsageIsOffAndNotConnectedStatesExist() {
        assertEquals("Plan usage is off", strings["widget_big_usage_off"])
        assertEquals("Turn it on in the app", strings["widget_big_usage_off_line"])
        assertEquals("Not connected", strings["widget_big_not_connected"])
        val root = element(bigLayout)
        assertTrue("one block for both calm messages", byId(root, "big_off").children().map { it.getAttribute("android:id") } == listOf("@+id/big_off_title", "@+id/big_off_line"))
        for (st in listOf("UsageSide.ROWS", "UsageSide.OFF", "UsageSide.NOT_CONNECTED")) assertTrue(st, bigSource.contains(st))
        assertTrue(bigSource.contains("R.string.widget_big_usage_off") && bigSource.contains("R.string.widget_big_usage_off_line") && bigSource.contains("R.string.widget_big_not_connected"))
        // "Plan usage is off" opens Settings through the whitelist; "Not connected" and the rows open the app.
        assertTrue(bigSource.contains("WidgetHub.openScreen(context, WidgetHub.CODE_BIG_USAGE_SETTINGS, LaunchScreen.SETTINGS)"))
        assertTrue(bigSource.contains("WidgetHub.openApp(context, WidgetHub.CODE_BIG_USAGE_APP)"))
        // The layout starts on the calm message, so an unpainted Widget is never an empty area.
        assertTrue(byId(root, "big_off").getAttribute("android:visibility").isEmpty())
        for (k in listOf("a", "b")) assertEquals("gone", byId(root, "big_usage_$k").getAttribute("android:visibility"))
    }

    @Test fun mochiBigHasTwoArrangementsOfTheSixButtons() {
        val root = element(bigLayout)
        val row = byId(root, "big_buttons_m").children().map { it.getAttribute("android:id") }
        assertEquals("one row of four", listOf("@+id/big_m_home", "@+id/big_m_chat", "@+id/big_m_settings", "@+id/big_m_recent"), row)
        val grid = byId(root, "big_buttons_l").children()
        assertEquals("two rows", 2, grid.size)
        assertEquals(
            listOf(
                listOf("@+id/big_l_home", "@+id/big_l_chat", "@+id/big_l_settings"),
                listOf("@+id/big_l_recent", "@+id/big_l_session", "@+id/big_l_pair"),
            ),
            grid.map { r -> r.children().map { it.getAttribute("android:id") } },
        )
        // Every tile: an icon over a 12sp label, on the rounded tile.
        val tiles = root.descendants().filter { it.getAttribute("android:id").startsWith("@+id/big_m_") || it.getAttribute("android:id").startsWith("@+id/big_l_") }
        assertEquals(10, tiles.size)
        for (t in tiles) {
            assertEquals(t.getAttribute("android:id"), "@drawable/widget_tile_bg", t.getAttribute("android:background"))
            assertEquals(listOf("ImageView", "TextView"), t.children().map { it.tagName })
            assertEquals("@dimen/widget_text_secondary", t.children()[1].getAttribute("android:textSize"))
        }
        assertEquals(12.0, dimens.getValue("widget_text_secondary"), 0.0)
        assertEquals("rounded 16dp", 16.0, dimens.getValue("widget_tile_radius"), 0.0)
    }

    @Test fun eachButtonOpensOneThingAndBothArrangementsAgree() {
        val src = bigSource
        assertTrue(src.contains("LaunchScreen.HOME, LaunchScreen.CHAT, LaunchScreen.SETTINGS, LaunchScreen.RECENT, null, LaunchScreen.PAIR"))
        assertTrue(src.contains("listOf(R.id.big_m_home, R.id.big_m_chat, R.id.big_m_settings, R.id.big_m_recent)"))
        assertTrue(src.contains("listOf(R.id.big_l_home, R.id.big_l_chat, R.id.big_l_settings, R.id.big_l_recent, R.id.big_l_session, R.id.big_l_pair)"))
        // The same button has the same code in the row and in the grid; each of the six has its own.
        assertTrue(src.contains("for (tiles in listOf(ROW_TILES, GRID_TILES))"))
        assertTrue(src.contains("WidgetHub.CODE_BIG_BUTTON + i"))
        // The top agent goes through the session slot, everything else through the screen slot.
        assertTrue(src.contains("WidgetHub.openSession(context, WidgetHub.CODE_BIG_BUTTON + i, top.pillId)"))
        assertTrue(src.contains("WidgetHub.openScreen(context, WidgetHub.CODE_BIG_BUTTON + i, screen)"))
        assertTrue(src.contains("R.drawable.widget_tile_bg_attention"))
    }

    @Test fun theBigOnesButtonsGoFromTwoRowsToOneRowToNone() {
        val src = bigSource
        assertTrue(src.contains("R.id.big_buttons, if (small) View.GONE else View.VISIBLE"))
        assertTrue(src.contains("R.id.big_buttons_m, if (large) View.GONE else View.VISIBLE"))
        assertTrue(src.contains("R.id.big_buttons_l, if (large) View.VISIBLE else View.GONE"))
        // Small: Mochi and the first row of usage only.
        assertTrue(src.contains("rows.getOrNull(1)?.takeIf { !small }"))
    }

    @Test fun mochiKeepsAtLeastFortyPercentOfTheTopAreaWheneverButtonsShow() {
        val medium = Regex("""MEDIUM_AT = SizeF\(0f, (\d+)f""").find(bigSource)!!.groupValues[1].toDouble()
        val large = Regex("""LARGE_AT = SizeF\(0f, (\d+)f""").find(bigSource)!!.groupValues[1].toDouble()
        val minHeight = Regex("""android:minHeight="(\d+)dp"""").find(read(res + "xml/coucou_big_widget_info.xml"))!!.groupValues[1].toDouble()
        val tile = dimens.getValue("widget_tile_height")
        val padding = 24.0
        // The top area is what the buttons leave; under Mochi sit the name row and the state word (about 20 + 16).
        val status = 36.0
        val small = minHeight - padding
        val withRow = medium - padding - (8 + tile)
        val withGrid = large - padding - (8 + tile + 6 + tile)
        for ((what, top) in listOf("small" to small, "one row" to withRow, "two rows" to withGrid)) {
            assertTrue("$what: the top area is ${top.toInt()}dp", top >= 100)
            assertTrue("$what: Mochi has ${(top - status).toInt()} of ${top.toInt()}dp", (top - status) / top >= 0.40)
        }
        // The two usage rows (label 15, percentage 35, bar 6, gaps) fit beside him at every size where both show.
        val twoRows = 2 * (15 + 35 + 2 + 6) + 8
        assertTrue("two usage rows need ${twoRows.toInt()}dp of ${withRow.toInt()}", twoRows <= withRow)
        assertTrue("the steps are in order", minHeight < medium && medium < large)
    }

    // ── Nothing here can approve, deny or send ──────────────────────────────────────────────────────

    @Test fun everyButtonOpensAScreenOfTheClosedListAndNothingElse() {
        for (f in listOf("app/StatusPillWidget.kt", "app/MochiBigWidget.kt")) {
            val src = read(main + f)
            for (word in listOf("PendingLaunch", "launch.request", "ActionReceiver", "approve", "Allow", "Deny", "decide", "send", "BiometricGate", "putExtra")) {
                assertFalse("$f uses $word", src.contains(word, ignoreCase = word != "send" && word != "Allow" && word != "Deny"))
            }
        }
        // Every screen a button names is on the list.
        val named = (read(main + "app/StatusPillWidget.kt") + read(main + "app/MochiBigWidget.kt"))
        for (m in Regex("""LaunchScreen\.([A-Z]+)""").findAll(named)) assertTrue(m.groupValues[1], LaunchScreen.values().any { it.name == m.groupValues[1] })
    }
}
