package com.coucou.android.ui

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.coucou.android.core.Palette
import com.coucou.android.core.StatusPalette
import com.coucou.android.core.ThemeChoice
import com.coucou.android.core.ThemePolicy
import com.coucou.android.core.Tokens

/**
 * The look of the Coucou website (docs/site.css): a near-black page (or a pale one in the light theme), slightly lighter cards with a
 * thin border, soft blue accent, rounded corners and pill-shaped buttons. Mochi itself is untouched.
 */
private fun scheme(p: Palette, t: Tokens): ColorScheme {
    // Surfaces and text come from the tokens, the accent from Palette.
    val base = if (t.isDark) darkColorScheme() else lightColorScheme()
    return base.copy(
        background = Color(t.bg), surface = Color(t.bg),
        surfaceVariant = Color(t.panel), surfaceContainer = Color(t.panel),
        onBackground = Color(t.text), onSurface = Color(t.text), onSurfaceVariant = Color(t.textDim),
        outline = Color(t.line), outlineVariant = Color(t.line),
        primary = Color(p.accent), onPrimary = Color(p.onAccent), error = Color(p.error),
    )
}

private fun Color.argb(): Long = toArgb().toLong() and 0xFFFFFFFFL

/** The tokens of the phone's own colours (Material You): surfaces, text and buttons from [cs]; the state and link colours stay ours. */
private fun fromDynamic(base: Tokens, cs: ColorScheme) = base.copy(
    bg = cs.surface.argb(), panel = cs.surfaceContainer.argb(), panel2 = cs.surfaceContainerHigh.argb(), line = cs.outlineVariant.argb(),
    text = cs.onSurface.argb(), textDim = cs.onSurfaceVariant.argb(), textFaint = cs.outline.argb(),
    primaryButton = cs.primary.argb(), onPrimaryButton = cs.onPrimary.argb(), secondaryButton = cs.secondaryContainer.argb(),
    danger = cs.error.argb(),
    hero = cs.surfaceContainerHigh.argb(), sheet = cs.surfaceContainerHigh.argb(),
    heroText = cs.onSurface.argb(), heroTextDim = cs.onSurfaceVariant.argb(),
    heroPrimary = cs.primary.argb(), heroOnPrimary = cs.onPrimary.argb(), heroButton = cs.secondaryContainer.argb(),
    heroLine = cs.outlineVariant.argb(),
)

/** Link status colours (the dot next to "Connected"). */
object StatusColors {
    val online = Color(StatusPalette.ONLINE)
    val busy = Color(StatusPalette.BUSY)
    val offline = Color(StatusPalette.OFFLINE)
}

/**
 * The theme: light, dark or the phone's own ([theme]), and optionally the phone's own colours ([dynamic], Android 12 and later).
 * Mochi, his colours and the state colours are the same in both.
 */
@Composable
fun CoucouTheme(theme: ThemeChoice = ThemeChoice.SYSTEM, dynamic: Boolean = false, content: @Composable () -> Unit) {
    val dark = ThemePolicy.dark(theme, isSystemInDarkTheme())
    val context = LocalContext.current
    var tokens = if (dark) Tokens.DARK else Tokens.LIGHT
    var colours = scheme(if (dark) Palette.DARK else Palette.LIGHT, tokens)
    if (dynamic && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && ThemePolicy.dynamicAvailable(Build.VERSION.SDK_INT)) {
        val cs = if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        tokens = fromDynamic(tokens, cs)
        colours = cs
    }
    CompositionLocalProvider(LocalTokens provides tokens) {
        MaterialTheme(colorScheme = colours, content = content)
    }
}

/** The gutter at the side of every screen, and the gap between cards (one rhythm everywhere). */
val Gutter = 16.dp
val Gap = 12.dp
