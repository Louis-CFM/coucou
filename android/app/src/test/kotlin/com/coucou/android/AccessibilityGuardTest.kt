package com.coucou.android

import com.coucou.android.core.Spacing
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** TalkBack, touch size and large text: guards on the Compose sources, which cannot run on a JVM. */
class AccessibilityGuardTest {
    private val ui = File("src/main/kotlin/com/coucou/android/ui")
    private fun src(name: String) = File(ui, name).readText()

    @Test fun theMinimumTouchTargetIs48dp() = assertEquals(48, Spacing.MIN_TOUCH)

    @Test fun everyTappableThingIsAtLeastAMinimumTouchTarget() {
        // Within the five lines above a click handler there must be a height (or size) of at least 48 dp, or the row is taller by design.
        val bigRows = Regex("""(heightIn\(min = (Spacing\.MIN_TOUCH|5\d|6\d|7\d)|sizeIn\(|\.size\((Spacing\.MIN_TOUCH|5\d|6\d)|ListRow\()""")
        for (f in ui.listFiles { it.extension == "kt" }!!.sortedBy { it.name }) {
            val lines = f.readLines()
            lines.forEachIndexed { i, line ->
                if (line.trimStart().startsWith("import")) return@forEachIndexed
                if (!(line.contains(".clickable(") || line.contains(".selectable(") || line.contains(".toggleable("))) return@forEachIndexed
                val window = lines.subList(maxOf(0, i - 5), i + 1).joinToString("\n")
                // The island's cards and the full-width settings rows are tall by construction; a scrim is not a control.
                val exempt = f.name == "IslandOverlay.kt" || line.contains("indication = null") || window.contains("fillMaxSize()")
                assertTrue("${f.name}:${i + 1} is tappable but its height is not at least 48 dp", exempt || bigRows.containsMatchIn(window))
            }
        }
    }

    @Test fun agentsAndTabsAreSpokenWithTheirStateNotOnlyAColour() {
        val home = src("HomePanel.kt")
        assertTrue(home.contains("SpokenLabels.agent(name, state, line)"))
        assertTrue(home.contains("SpokenLabels.agent(name, stringResource(stateLabel(state)), HomeText.line(focus))"))
        assertTrue(src("BottomBar.kt").contains("SpokenLabels.tab("))
    }

    @Test fun aRequestIsAnnouncedWhenItsSheetRises() {
        val sheets = src("Sheets.kt")
        assertTrue(sheets.contains("paneTitle = announce"))
        assertTrue(sheets.contains("SpokenLabels.approval("))
        // The scrim behind a sheet is a labelled button for TalkBack, not a silent area.
        assertTrue(sheets.contains("contentDescription = closeLabel"))
        // The island speaks too: a request at once.
        assertTrue(src("IslandOverlay.kt").contains("LiveRegionMode.Assertive"))
    }

    @Test fun aSheetScrollsSoALargeFontNeverHidesDenyOrAllow() {
        val sheets = src("Sheets.kt")
        val host = sheets.substringAfter("fun BottomSheetHost").substringBefore("/** The colour of an agent")
        assertTrue(host.contains(".verticalScroll(rememberScrollState())"))
    }

    @Test fun textThatCarriesAStateIsNotCutToOneLine() {
        // At a font scale of 1.3 these lines would lose their end; they may take two lines.
        val home = src("HomePanel.kt")
        assertTrue(home.contains("Text(line ?: state, style = TypeScale.SECONDARY.style(t.textDim.c()), maxLines = 2"))
        assertTrue(home.contains("Text(linkText, Modifier.weight(1f), style = TypeScale.LABEL.style(dim), maxLines = 2"))
        assertTrue(src("UsagePanel.kt").contains("maxLines = 2"))
        // A time and a count in a fixed 56 dp box would be cut by a large font.
        assertFalse(src("SettingsScreens.kt").contains("Modifier.width(56.dp)"))
    }

    @Test fun choicesAreReadAsSelectedRadioButtons() {
        val settings = src("SettingsScreens.kt")
        assertTrue(settings.contains("this.selected = value == selected") && settings.contains("role = Role.RadioButton"))
    }
}
