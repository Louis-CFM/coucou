package com.coucou.android

import com.coucou.android.core.Nav
import com.coucou.android.core.Screen
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Predictive back is on, and every screen and sheet still knows where Back goes. */
class PredictiveBackTest {
    private val main = "src/main/"

    @Test fun theAppAsksForPredictiveBack() {
        assertTrue(File(main + "AndroidManifest.xml").readText().contains("""android:enableOnBackInvokedCallback="true""""))
    }

    @Test fun everyScreenHasAPlaceToGoBackExceptHome() {
        assertNull("Back on Home leaves the app", Nav.back(Screen.HOME))
        for (s in Screen.values().filter { it != Screen.HOME }) {
            val up = Nav.back(s)
            assertTrue("$s has no Back", up != null)
            // One level up always ends on Home within two steps: no screen is a dead end or a loop.
            assertTrue(up == Screen.HOME || Nav.back(up!!) == Screen.HOME)
        }
        assertEquals(Screen.SETTINGS, Nav.back(Screen.HISTORY))
    }

    @Test fun everySheetClosesOnBack() {
        // The sheets that rise over a screen all go through one host, which owns the BackHandler.
        val sheets = File(main + "kotlin/com/coucou/android/ui/Sheets.kt").readText()
        assertTrue(sheets.contains("BackHandler(onBack = onDismiss)"))
        val ui = File(main + "kotlin/com/coucou/android/ui")
        for (name in listOf("DiffSheet.kt", "DiscoveryHint.kt", "PairingScreen.kt")) assertTrue(name, File(ui, name).readText().contains("BottomSheetHost"))
        // The activity owns the screen-level Back (no onBackPressed override: predictive back ignores it).
        val activity = File(main + "kotlin/com/coucou/android/MainActivity.kt").readText()
        assertTrue(activity.contains("BackHandler(enabled = Nav.back(screen) != null)"))
        assertTrue(!activity.contains("onBackPressed"))
    }
}
