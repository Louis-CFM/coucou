package com.coucou.android

import com.coucou.android.core.Palette
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** No dark text on a dark background: every text colour is readable on the surfaces it sits on (the app is dark only). */
class PaletteTest {
    private val themes = mapOf("dark" to Palette.DARK)

    @Test fun contrastMath() {
        assertEquals(21.0, Palette.contrast(0xFF000000, 0xFFFFFFFF), 0.01)
        assertEquals(1.0, Palette.contrast(0xFF123456, 0xFF123456), 1e-9)
    }

    @Test fun textIsReadableOnThePageAndOnCards() {
        for ((name, p) in themes) {
            for (surface in listOf(p.background, p.card)) {
                assertTrue("$name text", Palette.contrast(p.text, surface) >= 7.0)
                assertTrue("$name dim text", Palette.contrast(p.textDim, surface) >= 4.5)
                assertTrue("$name links", Palette.contrast(p.accent, surface) >= 4.5)
                assertTrue("$name errors", Palette.contrast(p.error, surface) >= 4.5)
            }
        }
    }

    @Test fun buttonTextIsReadableOnTheAccent() {
        for ((name, p) in themes) assertTrue("$name button", Palette.contrast(p.onAccent, p.accent) >= 4.5)
    }

    @Test fun cardsAreToldApartFromThePage() {
        for ((name, p) in themes) assertTrue("$name border", Palette.contrast(p.line, p.card) >= 1.1)
    }
}
