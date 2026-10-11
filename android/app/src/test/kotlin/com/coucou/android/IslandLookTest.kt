package com.coucou.android

import com.coucou.android.core.IslandGeometry
import com.coucou.android.core.PxRect
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The island on a 720x1600 phone with a small centred camera hole (the Galaxy A12s class). The
 * hole's rectangle is an assumption (about 56x66 px at the top centre), not a measurement: the real
 * inset is read from the display at run time.
 */
class IslandLookTest {
    private val density = 1.75f // 720 px wide = about 411 dp
    private val hole = PxRect(332, 0, 388, 66)
    private val box = IslandGeometry.place(720, density, hole, statusBarH = 70)

    private fun dp(px: Int) = px / density

    @Test fun theIslandIsCentredOnTheCameraHole() {
        assertEquals(0, box.centerOffsetX)
        assertEquals("content starts under the hole", 66, box.topInset)
    }

    @Test fun theWorkingStripIsNarrow() {
        assertTrue("working strip ${dp(box.workingW)} dp", dp(box.workingW) in 220f..260f)
    }

    @Test fun theResultAndRequestCardsAreWiderThanTheStrip() {
        assertTrue(box.cardW > box.workingW)
        assertTrue(box.approvalW >= box.cardW)
        assertTrue("fits the screen with a margin", box.cardW <= 720 - 2 * (12 * density).toInt())
    }

    @Test fun hiddenItIsJustAboveTheHoleSoItGrowsOutOfIt() {
        assertTrue("notch ${dp(box.notchWidth)} dp", dp(box.notchWidth) in 40f..70f)
        assertTrue(box.notchWidth > hole.width)
        assertTrue(box.notchWidth < box.workingW / 2)
    }

    @Test fun cornersAreThePCsFourteenAndTwentyTwo() {
        assertEquals(14, Math.round(dp(box.cornerSmall)))
        assertEquals(22, Math.round(dp(box.cornerLarge)))
    }

    @Test fun anOffCentreHoleStillKeepsTheWholeIslandOnScreen() {
        val right = IslandGeometry.place(720, density, PxRect(600, 0, 656, 66), statusBarH = 70)
        assertTrue(right.centerOffsetX > 0)
        assertTrue(right.centerOffsetX + right.approvalW / 2 <= 360)
    }

    @Test fun theFlaresFitBesideTheIslandOnANarrowPhone() {
        // 360 dp wide (1080 px at 3.0): island plus a flare on each side stays inside the screen with its margin.
        val narrow = IslandGeometry.place(1080, 3.0f, PxRect(504, 0, 576, 90), statusBarH = 90)
        val ear = (IslandGeometry.EAR_DP * 3.0f).toInt()
        assertTrue(narrow.approvalW + 2 * ear <= 1080 - 2 * (IslandGeometry.MARGIN_DP * 3.0f).toInt())
        assertEquals(14, IslandGeometry.EAR_DP) // the PC's flare
    }
}
