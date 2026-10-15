package com.coucou.android.core

/**
 * The screens a Widget button may open: a closed list, never a free string. A button carries the [key] of one of these to
 * LaunchActivity (ours, not exported), which turns it into a [LaunchScreen] with [parse] and hands it to the app inside
 * the process ([PendingLaunch]). Anything that is not in the list is rejected, so a button can only ever open a screen; none
 * changes or sends anything.
 */
enum class LaunchScreen(val key: String, val screen: Screen) {
    HOME("home", Screen.HOME),
    CHAT("chat", Screen.CHAT),
    SETTINGS("settings", Screen.SETTINGS),

    /** "Recent": the full list of your own decisions (the same one as Home's Recent, in full). */
    RECENT("recent", Screen.HISTORY),

    /** "Pair again": the pairing scan. It always asks to confirm before anything is paired. */
    PAIR("pair", Screen.SCAN),
    ;

    companion object {
        /** The screen called exactly [key]; null for anything else (another case, spaces, an unknown name, null). */
        fun parse(key: String?): LaunchScreen? = values().firstOrNull { it.key == key }
    }
}
