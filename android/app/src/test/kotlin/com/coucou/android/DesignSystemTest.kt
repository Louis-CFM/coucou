package com.coucou.android

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guards for the redesign's building blocks (the Compose code cannot be rendered in a JVM test, so
 * these read the sources): accessible controls, colours only from the tokens, no icon library.
 */
class DesignSystemTest {
    private fun src(name: String) = File("src/main/kotlin/com/coucou/android/$name").readText()
    private val system get() = src("ui/DesignSystem.kt")
    private val controls get() = src("ui/DesignControls.kt")
    private val icons get() = src("ui/DesignIcons.kt")

    @Test fun theSwitchIsARealToggleForTalkBack() {
        assertTrue(controls.contains("role = Role.Switch"))
        assertTrue(controls.contains("toggleable("))
    }

    @Test fun theSliderCanBeSteppedByTalkBack() {
        assertTrue(controls.contains("progressBarRangeInfo"))
        assertTrue(controls.contains("setProgress"))
        assertTrue(controls.contains("detectTapGestures") && controls.contains("detectHorizontalDragGestures"))
    }

    @Test fun everyControlIsAtLeast48DpToHit() {
        assertTrue(controls.contains("Spacing.MIN_TOUCH.dp"))
        assertTrue(system.contains("heightIn(min = Spacing.MIN_TOUCH.dp)"))
    }

    @Test fun buttonsAndRowsAnnounceThemselvesAsButtons() {
        assertTrue(system.contains("role = Role.Button"))
    }

    @Test fun iconsAreDrawnInCodeWithNoIconLibrary() {
        assertTrue(icons.contains("IconSpec.shapes("))
        val gradle = File("build.gradle.kts").readText()
        assertFalse(gradle.contains("material-icons"))
        assertFalse(gradle.contains("androidx.navigation"))
        for (text in listOf(system, controls, icons)) assertFalse(text.contains("androidx.compose.material.icons"))
    }

    @Test fun withAnimationsOffNothingSpringsOrSlides() {
        assertTrue(system.contains("fun reducedMotion()") && system.contains("ANIMATOR_DURATION_SCALE"))
        assertTrue("the switch snaps", controls.contains("if (reduced) snap()"))
        assertTrue("the sheet only fades", src("ui/Sheets.kt").contains("if (reducedMotion()) fadeIn(tween(MotionSpec.REDUCED_MS))"))
        assertTrue("the island jumps to its size", src("ui/IslandOverlay.kt").contains("if (reduced) { width.jump(w.toDouble())"))
    }

    @Test fun theBarGrowsWithTheFontInsteadOfCuttingItsLabels() {
        val bar = src("ui/BottomBar.kt")
        assertTrue(bar.contains("height(IntrinsicSize.Min).heightIn(min = 64.dp)"))
        assertTrue(bar.contains("maxLines = 1"))
    }

    @Test fun statusDotsUseTheThemeSafeColours() {
        val theme = src("ui/Theme.kt")
        for (c in listOf("ONLINE", "BUSY", "OFFLINE")) assertTrue(c, theme.contains("StatusPalette.$c"))
    }
}
