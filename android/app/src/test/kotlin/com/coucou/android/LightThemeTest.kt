package com.coucou.android

import com.coucou.android.core.KeyValueStore
import com.coucou.android.core.Palette
import com.coucou.android.core.ThemeChoice
import com.coucou.android.core.ThemePolicy
import com.coucou.android.core.Tokens
import com.coucou.android.core.UserSettings
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LightThemeTest {
    private val sets = mapOf("dark" to Tokens.DARK, "light" to Tokens.LIGHT)
    private fun c(a: Long, b: Long) = Palette.contrast(a, b)
    private fun ui(name: String) = File("src/main/kotlin/com/coucou/android/ui/$name").readText()

    @Test fun theChoiceDecidesTheSet() {
        assertTrue(ThemePolicy.dark(ThemeChoice.SYSTEM, systemDark = true))
        assertFalse(ThemePolicy.dark(ThemeChoice.SYSTEM, systemDark = false))
        assertFalse(ThemePolicy.dark(ThemeChoice.LIGHT, systemDark = true))
        assertTrue(ThemePolicy.dark(ThemeChoice.DARK, systemDark = false))
        assertEquals(Tokens.LIGHT, ThemePolicy.tokens(ThemeChoice.LIGHT, true))
        assertEquals(Tokens.DARK, ThemePolicy.tokens(ThemeChoice.DARK, false))
        assertTrue(Tokens.DARK.isDark)
        assertFalse(Tokens.LIGHT.isDark)
    }

    @Test fun materialYouNeedsAndroid12() {
        assertFalse(ThemePolicy.dynamicAvailable(30))
        assertTrue(ThemePolicy.dynamicAvailable(31))
        assertTrue(ThemePolicy.dynamicAvailable(35))
    }

    @Test fun theDefaultsFollowThePhoneAndKeepMyColoursOff() {
        val d = UserSettings()
        assertEquals(ThemeChoice.SYSTEM, d.theme)
        assertFalse(d.dynamicColour)
        assertEquals(ThemeChoice.SYSTEM, ThemeChoice.parse(null))
        assertEquals(ThemeChoice.SYSTEM, ThemeChoice.parse("sepia"))
        for (t in ThemeChoice.values()) assertEquals(t, ThemeChoice.parse(t.key))
        val m = HashMap<String, Any>()
        val store = object : KeyValueStore {
            override fun getBoolean(key: String, default: Boolean) = m[key] as? Boolean ?: default
            override fun getInt(key: String, default: Int) = m[key] as? Int ?: default
            override fun getFloat(key: String, default: Float) = m[key] as? Float ?: default
            override fun getString(key: String, default: String) = m[key] as? String ?: default
            override fun put(key: String, value: Any) { m[key] = value }
        }
        UserSettings.save(store, UserSettings(theme = ThemeChoice.LIGHT, dynamicColour = true))
        assertEquals(ThemeChoice.LIGHT, UserSettings.load(store).theme)
        assertTrue(UserSettings.load(store).dynamicColour)
    }

    @Test fun theHeroPanelsAndSheetsAreReadableInBothThemes() {
        for ((n, t) in sets) for (surface in listOf(t.hero, t.sheet)) {
            assertTrue("$n hero text", c(t.heroText, surface) >= 7.0)
            assertTrue("$n hero dim text", c(t.heroTextDim, surface) >= 4.5)
            assertTrue("$n main pill on the hero", c(t.heroPrimary, surface) >= 3.0)
            assertTrue("$n label of the main pill", c(t.heroOnPrimary, t.heroPrimary) >= 7.0)
            assertTrue("$n other pills on the hero", c(t.heroText, t.heroButton) >= 7.0)
            assertTrue("$n added lines", c(t.diffAdded, surface) >= 4.5)
            assertTrue("$n removed lines", c(t.diffRemoved, surface) >= 4.5)
        }
    }

    @Test fun theTwoThemesAreReallyDifferent() {
        assertNotEquals(Tokens.DARK.bg, Tokens.LIGHT.bg)
        assertTrue("the light page is light", c(Tokens.LIGHT.bg, 0xFFFFFFFF) < 1.2)
        assertTrue("the dark page is dark", c(Tokens.DARK.bg, 0xFF000000) < 1.3)
    }

    @Test fun onlyTheIslandAndTheCameraStayBlack() {
        // The hero, the sheets and every dialog take their colours from the tokens, so they follow the theme.
        for (f in File("src/main/kotlin/com/coucou/android/ui").listFiles { it.extension == "kt" }!!) {
            if (f.name == "IslandOverlay.kt" || f.name == "ScanScreen.kt") continue
            val text = f.readText()
            assertFalse("${f.name} hard-codes the island's black", text.contains("IslandSurface."))
            for (colour in listOf("Color.White", "Color.Black", "Color(0x")) {
                if (!text.contains(colour)) continue
                // The only ones left are the switch knob, the sheet scrim, the wardrobe tag, the bar's alert dot (the approval colour) and the state colours.
                assertTrue("${f.name} uses $colour", f.name in setOf("DesignControls.kt", "Sheets.kt", "WardrobeScreen.kt", "BottomBar.kt"))
            }
        }
        assertTrue("the island provides the dark tokens", ui("IslandOverlay.kt").contains("LocalTokens provides Tokens.DARK"))
        assertTrue("so does the camera screen", ui("ScanScreen.kt").contains("LocalTokens provides Tokens.DARK"))
    }

    @Test fun theThemeIsAppliedFromTheSettingAndTheSystem() {
        val theme = ui("Theme.kt")
        assertTrue(theme.contains("isSystemInDarkTheme()") && theme.contains("ThemePolicy.dark(theme"))
        assertTrue(theme.contains("dynamicLightColorScheme") && theme.contains("dynamicDarkColorScheme") && theme.contains("dynamicAvailable"))
        val main = File("src/main/kotlin/com/coucou/android/MainActivity.kt").readText()
        assertTrue(main.contains("CoucouTheme(model.settings.theme, model.settings.dynamicColour)"))
        // Dark icons on a light page, light icons on the camera.
        assertTrue(main.contains("isAppearanceLightStatusBars = lightPage") && main.contains("screen != Screen.SCAN"))
        assertTrue(File("src/main/res/values/themes.xml").readText().contains("DeviceDefault.DayNight"))
    }

    @Test fun settingsOffersTheThemeAndTheSwitchOnlyWhereItWorks() {
        val s = ui("SettingsScreens.kt")
        assertTrue(s.contains("ThemeChoice.LIGHT") && s.contains("ThemeChoice.DARK") && s.contains("R.string.settings_theme"))
        assertTrue(s.contains("ThemePolicy.dynamicAvailable(android.os.Build.VERSION.SDK_INT)") && s.contains("R.string.settings_dynamic"))
    }

    @Test fun mochiAndTheStateColoursDoNotDependOnTheTheme() {
        val home = ui("HomePanel.kt")
        assertTrue(home.contains("MochiConst.STATES[state]?.color?.let(::rgbColor)"))
        assertFalse(File("src/main/kotlin/com/coucou/android/mochi/MochiPainter.kt").readText().contains("LocalTokens"))
    }
}
