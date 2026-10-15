package com.coucou.android

import com.coucou.android.core.LaunchScreen
import com.coucou.android.core.Nav
import com.coucou.android.core.Screen
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The closed list of screens a Widget button may open: nothing else can be asked for. */
class LaunchScreenTest {
    @Test fun theListIsExactlyTheFiveScreensOfTheBrief() {
        assertEquals(listOf("home", "chat", "settings", "recent", "pair"), LaunchScreen.values().map { it.key })
        assertEquals(listOf(LaunchScreen.HOME, LaunchScreen.CHAT, LaunchScreen.SETTINGS, LaunchScreen.RECENT, LaunchScreen.PAIR), LaunchScreen.values().toList())
        assertEquals("a key is used once", 5, LaunchScreen.values().map { it.key }.toSet().size)
    }

    @Test fun everyValueParsesBackFromItsOwnKey() {
        for (s in LaunchScreen.values()) assertEquals(s, LaunchScreen.parse(s.key))
    }

    @Test fun anythingElseIsRejected() {
        val bad = listOf(
            null, "", " ", "HOME", "Home", " home", "home ", "ho me", "home\n", "session", "history", "scan", "diagnostics", "licences", "wardrobe",
            "approve", "allow", "deny", "send", "unpair", "SESSION", "../home", "home;chat", "0", "-1", "HOME,CHAT", "com.coucou.android.MainActivity",
        )
        for (k in bad) assertNull("'$k' must not open anything", LaunchScreen.parse(k))
        // The enum name is not the key: only the key is accepted.
        for (s in LaunchScreen.values()) assertNull(s.name, LaunchScreen.parse(s.name).takeIf { it != s })
    }

    @Test fun everyValueIsAScreenThatExistsInTheApp() {
        for (s in LaunchScreen.values()) assertTrue(s.name, s.screen in Screen.values())
        // The three tabs of the bottom bar.
        assertEquals(Nav.screenOf(com.coucou.android.core.Tab.HOME), LaunchScreen.HOME.screen)
        assertEquals(Nav.screenOf(com.coucou.android.core.Tab.CHAT), LaunchScreen.CHAT.screen)
        assertEquals(Nav.screenOf(com.coucou.android.core.Tab.SETTINGS), LaunchScreen.SETTINGS.screen)
        // "Recent" is the full list of your own decisions, one level under Settings; "Pair again" is the pairing scan.
        assertEquals(Screen.HISTORY, LaunchScreen.RECENT.screen)
        assertEquals(Screen.SCAN, LaunchScreen.PAIR.screen)
        assertEquals(Screen.SETTINGS, Nav.back(Screen.HISTORY))
        assertEquals(Screen.HOME, Nav.back(Screen.SCAN))
        // No screen that needs a session or a request in hand is on the list.
        assertFalse(LaunchScreen.values().any { it.screen == Screen.SESSION })
    }

    @Test fun onlyTheKeyTravelsAndOnlyTheNonExportedActivityParsesIt() {
        val main = "src/main/kotlin/com/coucou/android/"
        val launch = File(main + "app/LaunchActivity.kt").readText()
        assertTrue(launch.contains("LaunchScreen.parse(intent.getStringExtra(EXTRA_SCREEN))"))
        val hub = File(main + "app/WidgetHub.kt").readText()
        // A button is built from a LaunchScreen value, never from a free string.
        assertTrue(hub.contains("fun openScreen(context: Context, code: Int, screen: LaunchScreen): PendingIntent"))
        assertTrue(hub.contains(".putExtra(LaunchActivity.EXTRA_SCREEN, screen.key)"))
        assertFalse(File(main + "MainActivity.kt").readText().contains("EXTRA_SCREEN"))
        assertFalse(File(main + "MainActivity.kt").readText().contains("LaunchScreen.parse"))
        val manifest = File("src/main/AndroidManifest.xml").readText()
        assertTrue(manifest.substringAfter(""".app.LaunchActivity"""").substringBefore("/>").contains("""android:exported="false""""))
    }
}
