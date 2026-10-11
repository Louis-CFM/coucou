package fr.louisraille.coucou.phone

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

/**
 * Coucou's look on the phone mirrors the iPhone app (NotchBuddy/Sources/Phone):
 * always dark, black background, cards at white-11%, pills at white-16%, and
 * the accent comes from the agent's state — never from Material's palette.
 * The dark scheme is the identity (the iOS app hardcodes Color.black too).
 */
object Coucou {
    // Fills
    val Card = Color(0xFF1C1C1E)          // white 0.11
    val Pill = Color(0xFF29292B)          // white 0.16
    val CardSoft = Color(0xFF171718)      // white 0.09 — the island header
    val Field = Color(0x14FFFFFF)         // white 0.08 — inputs, code blocks
    val Hairline = Color(0x1FFFFFFF)      // white 0.12 — island border
    val CardStroke = Color(0x12FFFFFF)    // white 0.07 — subtle card border

    // Text
    val Ink = Color(0xFFF5F5F7)
    val Secondary = Color(0x99FFFFFF)     // white 0.60
    val Tertiary = Color(0x4DFFFFFF)      // white 0.30

    // State accents — the BotStates palette from CoucouKit/BotEngine.swift
    val Approval = Color(0xFFF5A524)      // rgb(0.961, 0.647, 0.141)
    val Question = Color(0xFF22D3EE)      // rgb(0.133, 0.827, 0.933)
    val Error = Color(0xFFF4505E)         // rgb(0.957, 0.314, 0.369)
    val Done = Color(0xFF34D399)          // rgb(0.204, 0.831, 0.600)
    val Working = Color(0xFF3B9EFF)       // rgb(0.231, 0.620, 1.000)
    val Thinking = Color(0xFF8B5CF6)      // rgb(0.545, 0.361, 0.965)
    val RateLimit = Color(0xFFFB923C)     // rgb(0.984, 0.573, 0.235)
    val Sleeping = Color(0xFF94A2B8)      // rgb(0.580, 0.635, 0.722)

    // The iOS approval buttons: Allow is solid systemGreen with dark text,
    // Deny is a translucent red capsule with a light-red label.
    val Allow = Color(0xFF30D158)
    val DenyBg = Color(0x33F4505E)
    val DenyInk = Color(0xFFFF9EA6)

    // Shape — iOS uses 22/26/28
    val CornerCard = 22.dp
    val CornerPanel = 26.dp
    val CornerIsland = 28.dp
    val CornerTile = 11.dp

    /** The color a session's status text takes, by state name. */
    fun accentFor(state: String): Color = when (state) {
        "approval" -> Approval
        "question" -> Question
        "error" -> Error
        "finished" -> Done
        "working" -> Working
        "thinking" -> Thinking
        "searching" -> Thinking
        "ratelimit" -> RateLimit
        "sleeping" -> Sleeping
        else -> Secondary
    }
}

@Composable
fun CoucouTheme(content: @Composable () -> Unit) {
    // Always dark — the phone app is the island, and the island is black.
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = Coucou.Ink,
            onPrimary = Color.Black,
            surface = Coucou.Card,
            surfaceVariant = Coucou.Pill,
            onSurface = Coucou.Ink,
            onSurfaceVariant = Coucou.Secondary,
            background = Color.Black,
            onBackground = Coucou.Ink,
            error = Coucou.Error,
            outline = Coucou.Hairline,
        ),
        content = content,
    )
}
