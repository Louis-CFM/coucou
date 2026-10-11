package com.coucou.android

import com.coucou.android.core.IslandSurface
import com.coucou.android.core.MotionSpec
import com.coucou.android.core.Palette
import com.coucou.android.core.StatusPalette
import com.coucou.android.core.Radii
import com.coucou.android.core.Spacing
import com.coucou.android.core.Tokens
import com.coucou.android.core.TypeScale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The redesign's tokens: readable text on every surface it sits on, on the dark theme, and a scale that holds together. */
class TokensTest {
    private val themes = mapOf("dark" to Tokens.DARK)
    private fun c(a: Long, b: Long) = Palette.contrast(a, b)

    @Test fun primaryTextIsReadableOnEverySurface() {
        for ((n, t) in themes) for (s in listOf(t.bg, t.panel, t.panel2, t.secondaryButton)) {
            assertTrue("$n text on ${s.toString(16)}", c(t.text, s) >= 7.0)
            assertTrue("$n dim text on ${s.toString(16)}", c(t.textDim, s) >= 4.5 || s == t.panel2 && c(t.textDim, s) >= 4.0)
        }
    }

    @Test fun dimTextIsReadableOnThePageAndOnPanels() {
        for ((n, t) in themes) for (s in listOf(t.bg, t.panel)) assertTrue("$n dim on ${s.toString(16)}", c(t.textDim, s) >= 4.5)
    }

    @Test fun faintTextIsOnlyForLargeTextAndIcons() {
        for ((n, t) in themes) for (s in listOf(t.bg, t.panel)) assertTrue("$n faint", c(t.textFaint, s) >= 3.0)
    }

    @Test fun theMainButtonAndItsLabelAreReadable() {
        for ((n, t) in themes) {
            assertTrue("$n label", c(t.onPrimaryButton, t.primaryButton) >= 7.0)
            assertTrue("$n button stands out from the panel", c(t.primaryButton, t.panel) >= 3.0)
        }
    }

    @Test fun dangerTextIsReadableAndGreenIsVisibleAsADot() {
        for ((n, t) in themes) for (s in listOf(t.bg, t.panel)) {
            assertTrue("$n danger", c(t.danger, s) >= 4.5)
            assertTrue("$n online dot", c(t.online, s) >= 3.0)
        }
    }

    @Test fun panelsAreToldApartFromThePage() {
        for ((n, t) in themes) {
            assertTrue("$n panel border", c(t.line, t.panel) >= 1.1)
            assertTrue("$n panel vs page", c(t.panel, t.bg) >= 1.05)
            assertTrue("$n row vs panel", c(t.panel2, t.panel) >= 1.05)
        }
    }

    @Test fun secondaryButtonsAreVisibleOnPanels() {
        for ((n, t) in themes) assertTrue("$n secondary", c(t.secondaryButton, t.panel) >= 1.05)
    }

    @Test fun theAlwaysDarkIslandKeepsItsTextReadable() {
        for (bg in listOf(IslandSurface.BLACK, IslandSurface.PANEL, IslandSurface.HERO)) {
            assertTrue(c(IslandSurface.TEXT, bg) >= 7.0)
            assertTrue(c(IslandSurface.TEXT_DIM, bg) >= 4.5)
        }
    }

    @Test fun theWashIsSoft() {
        assertTrue(Tokens.DARK.washAlpha in 0.3..0.6)
    }

    @Test fun spacingIsOneScaleOnAFourPointGrid() {
        assertTrue(Spacing.SCALE.all { it % 4 == 0 })
        assertEquals(Spacing.SCALE.sorted(), Spacing.SCALE)
        assertTrue(Spacing.GUTTER in Spacing.SCALE && Spacing.GAP in Spacing.SCALE && Spacing.INSIDE in Spacing.SCALE)
        assertEquals(48, Spacing.MIN_TOUCH)
    }

    @Test fun typeScaleGrowsAndHasRoomForItsLines() {
        val sizes = TypeScale.ALL.map { it.sizeSp }
        assertEquals(sizes.sortedDescending(), sizes)
        for (t in TypeScale.ALL) {
            assertTrue("${t.name} line height", t.lineSp >= t.sizeSp + 4)
            assertTrue("${t.name} weight", t.weight in 400..700)
        }
        assertTrue("body text is at least 15 sp", TypeScale.BODY.sizeSp >= 15)
        assertTrue("nothing under 12 sp", TypeScale.ALL.all { it.sizeSp >= 12 })
    }

    @Test fun radiiMatchThePc() {
        assertEquals(20, Radii.PANEL)
        assertEquals(22, Radii.ISLAND_EXPANDED)
        assertEquals(14, Radii.ISLAND_COMPACT)
    }

    @Test fun statusDotsAreVisibleOnBlackAndDarkPanels() {
        val surfaces = listOf(Tokens.DARK.bg, Tokens.DARK.panel, IslandSurface.HERO, IslandSurface.BLACK)
        for (c in listOf(StatusPalette.ONLINE, StatusPalette.BUSY, StatusPalette.OFFLINE)) for (s in surfaces) {
            assertTrue("${c.toString(16)} on ${s.toString(16)}", Palette.contrast(c, s) >= 3.0)
        }
    }

    @Test fun reducedMotionFollowsTheAnimatorScale() {
        assertTrue(MotionSpec.isReduced(0f))
        assertTrue(!MotionSpec.isReduced(1f) && !MotionSpec.isReduced(0.5f))
    }
}
