package fr.louisraille.coucou.phone

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

private val Dark = darkColorScheme(
    primary = Color(0xFF9CCBFF),
    onPrimary = Color(0xFF0B3050),
    primaryContainer = Color(0xFF1F4A73),
    onPrimaryContainer = Color(0xFFD3E4FF),
    secondary = Color(0xFFBAC8DB),
    surface = Color(0xFF121318),
    surfaceVariant = Color(0xFF1E2028),
    onSurface = Color(0xFFE3E2E9),
    onSurfaceVariant = Color(0xFFC4C6D0),
    background = Color(0xFF0B0C10),
    error = Color(0xFFFFB4AB),
)

private val Light = lightColorScheme(
    primary = Color(0xFF1F5FA6),
    surfaceVariant = Color(0xFFE1E2EC),
)

@Composable
fun CoucouTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = if (isSystemInDarkTheme()) Dark else Light,
        content = content,
    )
}
