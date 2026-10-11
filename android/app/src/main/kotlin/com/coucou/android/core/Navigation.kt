package com.coucou.android.core

/** The three places the bottom bar leads to. */
enum class Tab { HOME, CHAT, SETTINGS }

/** Every screen of the app. Tabs are the roots; the rest are one level down. */
enum class Screen { HOME, CHAT, SETTINGS, HISTORY, GALLERY, WARDROBE, DIAGNOSTICS, LICENCES, SESSION, SCAN }

/**
 * Where the user is and where Back goes. Pure, so every rule is a unit test:
 * - the bar always has Home, Chat and Settings (Chat shows why it cannot chat yet when that is the case);
 * - the bar shows on the three tab roots, and hides on every page below them and while the keyboard is open;
 * - Back goes up one level; on Home it is the system's (leave the app).
 */
object Nav {
    /** Home, Chat and Settings, always: Chat explains itself when the computer does not offer it. */
    fun tabs(): List<Tab> = listOf(Tab.HOME, Tab.CHAT, Tab.SETTINGS)

    fun screenOf(tab: Tab): Screen = when (tab) {
        Tab.HOME -> Screen.HOME
        Tab.CHAT -> Screen.CHAT
        Tab.SETTINGS -> Screen.SETTINGS
    }

    /** The tab a screen belongs to, so the bar can highlight it; null for full-screen tasks. */
    fun tabOf(screen: Screen): Tab? = when (screen) {
        Screen.HOME -> Tab.HOME
        Screen.CHAT -> Tab.CHAT
        Screen.SETTINGS, Screen.HISTORY, Screen.GALLERY, Screen.WARDROBE, Screen.DIAGNOSTICS, Screen.LICENCES -> Tab.SETTINGS
        Screen.SESSION, Screen.SCAN -> null
    }

    fun barVisible(screen: Screen, keyboardOpen: Boolean): Boolean =
        !keyboardOpen && screen in setOf(Screen.HOME, Screen.CHAT, Screen.SETTINGS)

    /** One level up, or null when Back should leave the app. */
    fun back(screen: Screen): Screen? = when (screen) {
        Screen.HOME -> null
        Screen.CHAT, Screen.SETTINGS, Screen.SESSION, Screen.SCAN -> Screen.HOME
        Screen.HISTORY, Screen.GALLERY, Screen.WARDROBE, Screen.DIAGNOSTICS, Screen.LICENCES -> Screen.SETTINGS
    }
}
