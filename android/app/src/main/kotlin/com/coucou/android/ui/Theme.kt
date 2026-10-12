package com.coucou.android.ui

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.coucou.android.core.Palette
import com.coucou.android.core.StatusPalette
import com.coucou.android.core.Tokens

/**
 * The look of the Coucou website (docs/site.css): near-black page, slightly lighter cards with a thin
 * border, soft blue accent, rounded corners and pill-shaped buttons. Mochi itself is untouched.
 */
private fun scheme(p: Palette, t: Tokens): ColorScheme {
    // Surfaces and text come from the tokens, the accent from Palette.
    return darkColorScheme().copy(
        background = Color(t.bg), surface = Color(t.bg),
        surfaceVariant = Color(t.panel), surfaceContainer = Color(t.panel),
        onBackground = Color(t.text), onSurface = Color(t.text), onSurfaceVariant = Color(t.textDim),
        outline = Color(t.line), outlineVariant = Color(t.line),
        primary = Color(p.accent), onPrimary = Color(p.onAccent), error = Color(p.error),
    )
}

private val Dark = scheme(Palette.DARK, Tokens.DARK)

/** Link status colours (the dot next to "Connected"). */
object StatusColors {
    val online = Color(StatusPalette.ONLINE)
    val busy = Color(StatusPalette.BUSY)
    val offline = Color(StatusPalette.OFFLINE)
}

@Composable
fun CoucouTheme(content: @Composable () -> Unit) {
    CompositionLocalProvider(LocalTokens provides Tokens.DARK) {
        MaterialTheme(colorScheme = Dark, content = content)
    }
}

/** The gutter at the side of every screen, and the gap between cards (one rhythm everywhere). */
val Gutter = 16.dp
val Gap = 12.dp
