package com.coucou.android.mochi.outfit

import java.io.File
import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WardrobeChoiceTest {
    private val day = LocalDate.of(2026, 10, 10) // witch hat season

    @Test fun followingTheComputerWearsWhatItSays() {
        assertEquals("beanie", Wardrobe.choose(Wardrobe.FOLLOW, "beanie"))
        assertEquals(Outfit.BEANIE, Wardrobe.resolve(Wardrobe.choose(Wardrobe.FOLLOW, "beanie"), day))
        assertEquals(Outfit.WITCH_HAT, Wardrobe.resolve(Wardrobe.choose(Wardrobe.FOLLOW, "auto"), day))
    }

    @Test fun aChoiceOfTheUserBeatsTheComputer() {
        assertEquals("crown", Wardrobe.choose("crown", "beanie"))
        assertEquals(Outfit.NONE, Wardrobe.resolve(Wardrobe.choose("none", "beanie"), day))
        assertEquals(Outfit.WITCH_HAT, Wardrobe.resolve(Wardrobe.choose("auto", "none"), day))
    }

    @Test fun garbageFromEitherSideIsHarmless() {
        assertEquals("auto", Wardrobe.choose(Wardrobe.FOLLOW, "topHat"))
        assertEquals("computer", Wardrobe.parseLocal("x"))
        assertEquals(Outfit.NONE, Wardrobe.outfitOf("x"))
    }

    // The screens cannot be drawn in a JVM test, so these read the sources.
    private fun src(name: String) = File("src/main/kotlin/com/coucou/android/$name").readText()

    @Test fun theWardrobeIsOneTapFromSettingsAndGoesBackToSettings() {
        assertTrue(src("ui/SettingsScreens.kt").contains("onWardrobe"))
        assertTrue(src("MainActivity.kt").contains("Screen.WARDROBE -> WardrobeScreen"))
        assertTrue(src("core/Navigation.kt").contains("Screen.HISTORY, Screen.GALLERY, Screen.WARDROBE, Screen.DIAGNOSTICS, Screen.LICENCES -> Screen.SETTINGS"))
    }

    @Test fun everyWardrobeValueHasAnEnglishName() {
        val xml = File("src/main/res/values/strings.xml").readText()
        for (id in Wardrobe.SELECTIONS) assertTrue("outfit_$id", xml.contains("name=\"outfit_$id\""))
        val screen = src("ui/WardrobeScreen.kt")
        for (id in Wardrobe.SELECTIONS.filter { it != "bunnyEars" }) assertTrue(id, screen.contains("\"$id\" -> R.string.outfit_$id"))
    }

    @Test fun theIconsAreDrawnByTheSameCodeAsTheBigMochi() {
        val screen = src("ui/WardrobeScreen.kt")
        assertTrue(screen.contains("drawIconMochi("))
        assertTrue(src("mochi/MochiPainter.kt").contains("drawOutfitFront(") && src("mochi/MochiPainter.kt").contains("drawOutfitBehind("))
    }

    @Test fun homeDressesTheHeroAndOnlyTheHero() {
        val main = src("MainActivity.kt")
        assertTrue(main.contains("engine.setOutfit("))
        assertEquals("only the hero's engine is dressed", 2, Regex("""setOutfit\(""").findAll(main).count())
        assertFalse(src("mochi/MochiEngine.kt").contains("isMini) outfit"))
    }

    @Test fun nothingAboutTheOutfitLeavesThePhone() {
        for (f in listOf("ui/WardrobeScreen.kt", "mochi/outfit/Wardrobe.kt")) {
            val s = src(f)
            assertFalse(f, s.contains("Log.") || s.contains("Socket") || s.contains("http"))
        }
    }
}
