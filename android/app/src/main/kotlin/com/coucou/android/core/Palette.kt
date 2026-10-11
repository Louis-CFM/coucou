package com.coucou.android.core

import kotlin.math.pow

/**
 * The app's colours as plain 0xAARRGGBB numbers, so a test can check that text stays readable on
 * its background (Theme.kt turns them into Compose colours). The app is dark only.
 */
data class Palette(
    val background: Long, val card: Long, val line: Long,
    val text: Long, val textDim: Long, val accent: Long, val onAccent: Long, val error: Long,
) {
    companion object {
        val DARK = Palette(
            background = 0xFF0E0F12, card = 0xFF16171B, line = 0xFF26282E,
            text = 0xFFF3F4F6, textDim = 0xFFA1A6B0, accent = 0xFF8AB4FF, onAccent = 0xFF0E0F12, error = 0xFFFF8A80,
        )

        private fun lin(c: Int): Double {
            val v = c / 255.0
            return if (v <= 0.03928) v / 12.92 else ((v + 0.055) / 1.055).pow(2.4)
        }

        private fun luminance(argb: Long): Double {
            val r = ((argb shr 16) and 0xFF).toInt()
            val g = ((argb shr 8) and 0xFF).toInt()
            val b = (argb and 0xFF).toInt()
            return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        }

        /** WCAG contrast ratio, 1 (none) to 21 (black on white). */
        fun contrast(a: Long, b: Long): Double {
            val la = luminance(a)
            val lb = luminance(b)
            return (maxOf(la, lb) + 0.05) / (minOf(la, lb) + 0.05)
        }
    }
}
