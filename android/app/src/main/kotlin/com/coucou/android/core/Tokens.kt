package com.coucou.android.core

/**
 * The design tokens as plain numbers, so a test can check contrast and the scale without Compose. There are two sets, dark and light
 * (Settings > Theme); the island over other apps and the camera screen are always dark.
 *
 * Louis Raillé's Mochi, its state colours and the pill colours are not here and are not changed.
 */
data class Tokens(
    /** The screen. */
    val bg: Long,
    /** Island panels and cards. */
    val panel: Long,
    /** Rows inside a panel, chips, the selected tab. */
    val panel2: Long,
    /** The thin border of a panel. */
    val line: Long,
    val text: Long,
    val textDim: Long,
    /** Hints and placeholders: large text and icons only. */
    val textFaint: Long,
    /** The one main action: a pill, as on the PC. */
    val primaryButton: Long, val onPrimaryButton: Long,
    /** Every other pill, as a solid colour on [panel]. */
    val secondaryButton: Long,
    val danger: Long,
    /** The "connected" dot and the on switch. */
    val online: Long,
    /** Alpha of the coloured glow at the bottom of a panel (0..1). */
    val washAlpha: Double,
    /** True for the dark set (status bar icons, the Material colour scheme and the dim of a scrim follow it). */
    val isDark: Boolean = true,
    /**
     * The hero panel on Home and the sheets (request, question, file changes): the island grown to full width. Black in the dark set,
     * a light card in the light one; the island itself always provides the dark set, so the same code draws both.
     */
    val hero: Long = 0xFF0E0F12, val sheet: Long = 0xFF141518,
    val heroText: Long = 0xFFF5F6F8, val heroTextDim: Long = 0xFF9398A1,
    /** The main pill on a hero surface and its label; every other pill on it. */
    val heroPrimary: Long = 0xFFF5F6F8, val heroOnPrimary: Long = 0xFF0B0C0E, val heroButton: Long = 0xFF2A2B2E,
    /** The thin edge of a hero panel or a sheet, and the faint fill of a row or a chip on it (alpha is part of the colour). */
    val heroLine: Long = 0x0FFFFFFF, val heroFill: Long = 0x12FFFFFF,
    /** The colours of an added and a removed line of a file change, readable on [sheet]. */
    val diffAdded: Long = 0xFF34D399, val diffRemoved: Long = 0xFFFF8D97,
) {
    companion object {
        val DARK = Tokens(
            bg = 0xFF000000, panel = 0xFF141518, panel2 = 0xFF1D1F23, line = 0xFF26282D,
            text = 0xFFF5F6F8, textDim = 0xFF9398A1, textFaint = 0xFF6E737C,
            primaryButton = 0xFFF5F6F8, onPrimaryButton = 0xFF0B0C0E, secondaryButton = 0xFF292A2D,
            danger = 0xFFFF8D97, online = 0xFF34D399, washAlpha = 0.5,
        )

        /** The light set: a pale page, white cards, near-black text; every pair is checked for WCAG AA in TokensTest. */
        val LIGHT = Tokens(
            bg = 0xFFF4F5F7, panel = 0xFFFFFFFF, panel2 = 0xFFECEEF1, line = 0xFFD8DBE0,
            text = 0xFF14161A, textDim = 0xFF575D67, textFaint = 0xFF6B717B,
            primaryButton = 0xFF14161A, onPrimaryButton = 0xFFF5F6F8, secondaryButton = 0xFFE4E6EA,
            danger = 0xFFB3261E, online = 0xFF0B8A5E, washAlpha = 0.28,
            isDark = false,
            hero = 0xFFFFFFFF, sheet = 0xFFFFFFFF,
            heroText = 0xFF14161A, heroTextDim = 0xFF575D67,
            heroPrimary = 0xFF14161A, heroOnPrimary = 0xFFF5F6F8, heroButton = 0xFFE4E6EA,
            heroLine = 0xFFD8DBE0, heroFill = 0x14000000,
            diffAdded = 0xFF0B7A55, diffRemoved = 0xFFB3261E,
        )
    }
}

/** The black surfaces: the hero panel on Home and the island over other apps. */
object IslandSurface {
    const val BLACK = 0xFF000000L
    const val PANEL = 0xFF141518L
    const val HERO = 0xFF0E0F12L
    const val TEXT = 0xFFF5F6F8L
    const val TEXT_DIM = 0xFF9398A1L
    const val ON_PRIMARY = 0xFF0B0C0EL
}

/**
 * The link dot colours: each is visible (3:1 or better) on black and on the dark panels.
 */
object StatusPalette {
    const val ONLINE = 0xFF0F9F6EL
    const val BUSY = 0xFFB45309L
    const val OFFLINE = 0xFF6B7280L
}

/** The spacing scale (dp): every gap, padding and gutter is one of these. */
object Spacing {
    val SCALE = listOf(4, 8, 12, 16, 24, 32)
    const val GUTTER = 16
    const val GAP = 12
    const val INSIDE = 16
    /** The smallest thing a finger must be able to hit, in dp. */
    const val MIN_TOUCH = 48
}

/** Corner radii (dp). Pills and chips are fully round. */
object Radii {
    const val PANEL = 20
    const val SHEET = 28
    const val ISLAND_EXPANDED = 22
    const val ISLAND_COMPACT = 14
    const val HERO_BOTTOM = 30
}

/** One step of the type scale: sizes are sp, so the user's font size setting applies. */
data class TypeStep(val name: String, val sizeSp: Int, val lineSp: Int, val weight: Int)

object TypeScale {
    val DISPLAY = TypeStep("display", 28, 34, 700)
    val TITLE = TypeStep("title", 20, 26, 700)
    val HEADLINE = TypeStep("headline", 16, 22, 600)
    val BODY = TypeStep("body", 15, 22, 400)
    val SECONDARY = TypeStep("secondary", 13, 18, 400)
    val LABEL = TypeStep("label", 12, 16, 600)
    /** Only for the exact command and code in chat. */
    val MONO = TypeStep("mono", 12, 18, 400)
    val ALL = listOf(DISPLAY, TITLE, HEADLINE, BODY, SECONDARY, LABEL, MONO)
}

/** Motion constants shared with the PC (see core/IslandMotion.kt for the springs). */
object MotionSpec {
    const val RETRACT_MS = 340
    /** With "remove animations" on, a spring or a slide becomes this fade. */
    const val REDUCED_MS = 120

    /** Android's "Remove animations" (and developer "animator duration scale: off") sets the scale to 0. */
    fun isReduced(animatorDurationScale: Float): Boolean = animatorDurationScale <= 0f
}
