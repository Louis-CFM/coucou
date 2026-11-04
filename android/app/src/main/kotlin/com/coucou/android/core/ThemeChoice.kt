package com.coucou.android.core

/** Settings > Theme: follow the phone (the default), or always light, or always dark. */
enum class ThemeChoice(val key: String) {
    SYSTEM("system"), LIGHT("light"), DARK("dark");

    companion object {
        /** An unknown or missing key follows the system. */
        fun parse(key: String?): ThemeChoice = values().firstOrNull { it.key == key } ?: SYSTEM
    }
}

object ThemePolicy {
    /** Whether the dark set is in force, given the choice and whether the phone is in dark mode. */
    fun dark(choice: ThemeChoice, systemDark: Boolean): Boolean = when (choice) {
        ThemeChoice.LIGHT -> false
        ThemeChoice.DARK -> true
        ThemeChoice.SYSTEM -> systemDark
    }

    fun tokens(choice: ThemeChoice, systemDark: Boolean): Tokens = if (dark(choice, systemDark)) Tokens.DARK else Tokens.LIGHT

    /** The Material You colours need Android 12 (API 31); before that the switch has nothing to follow. */
    fun dynamicAvailable(sdk: Int): Boolean = sdk >= 31
}
