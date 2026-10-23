package com.coucou.android

import com.coucou.android.core.IconKind
import com.coucou.android.core.IconShape
import com.coucou.android.core.IconSpec
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class IconSpecTest {
    @Test fun everyIconHasADrawing() {
        for (k in IconKind.entries) assertTrue("$k", IconSpec.shapes(k).isNotEmpty())
    }

    @Test fun everythingStaysOnTheGridWithRoomForTheStroke() {
        val margin = IconSpec.STROKE / 2
        for (k in IconKind.entries) for (v in IconSpec.extent(k)) {
            assertTrue("$k point $v", v >= margin && v <= IconSpec.GRID - margin)
        }
    }

    @Test fun polylinesHavePairsAndAtLeastTwoPoints() {
        for (k in IconKind.entries) for (s in IconSpec.shapes(k)) if (s is IconShape.Poly) {
            assertEquals("$k", 0, s.points.size % 2)
            assertTrue("$k", s.points.size >= 4)
        }
    }

    @Test fun noTwoIconsAreTheSameDrawing() {
        assertEquals(IconKind.entries.size, IconKind.entries.map { IconSpec.shapes(it) }.toSet().size)
    }

    @Test fun theSettingsIconIsNotASunOrAGear() {
        // The old gear was a ring with eight spokes. Settings is two rails with two knobs.
        val s = IconSpec.shapes(IconKind.SLIDERS)
        assertEquals(2, s.count { it is IconShape.Circle })
        assertTrue(s.none { it is IconShape.Arc })
        assertTrue(s.filterIsInstance<IconShape.Poly>().all { p -> p.points[1] == p.points[3] }) // every rail is horizontal
    }

    @Test fun strokeIsTheSameAsThePc() {
        assertEquals(1.9, IconSpec.STROKE, 0.0)
    }

    @Test fun onlyTheIconsThatPointAlongTheReadingDirectionAreMirroredForArabic() {
        val mirrored = com.coucou.android.core.IconKind.values().filter { com.coucou.android.core.IconSpec.mirrorsInRtl(it) }
        org.junit.Assert.assertEquals(listOf(com.coucou.android.core.IconKind.BACK, com.coucou.android.core.IconKind.SEND, com.coucou.android.core.IconKind.CHEVRON), mirrored)
        // A chevron turned to point down is not mirrored by its caller.
        org.junit.Assert.assertTrue(java.io.File("src/main/kotlin/com/coucou/android/ui/ChatScreen.kt").readText().contains("rotate(90f), mirror = false"))
    }
}
