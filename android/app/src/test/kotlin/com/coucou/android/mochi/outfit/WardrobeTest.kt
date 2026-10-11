package com.coucou.android.mochi.outfit

import com.coucou.android.ReferenceFiles
import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors windows/tests/wardrobe.test.mjs so the phone and the PC dress Mochi alike. */
class WardrobeTest {
    private fun season(y: Int, m: Int, d: Int) = Wardrobe.seasonal(LocalDate.of(y, m, d))

    @Test fun witchHatFromOctoberFirstToNovemberFirst() {
        assertEquals(Outfit.NONE, season(2026, 9, 30))
        assertEquals(Outfit.WITCH_HAT, season(2026, 10, 1))
        assertEquals(Outfit.WITCH_HAT, season(2026, 10, 31))
        assertEquals(Outfit.WITCH_HAT, season(2026, 11, 1))
        assertEquals(Outfit.NONE, season(2026, 11, 2))
    }

    @Test fun santaHatFromDecemberFirstToTwentySixth() {
        assertEquals(Outfit.NONE, season(2026, 11, 30))
        assertEquals(Outfit.SANTA_HAT, season(2026, 12, 1))
        assertEquals(Outfit.SANTA_HAT, season(2026, 12, 26))
        assertEquals(Outfit.NONE, season(2026, 12, 27))
    }

    @Test fun partyHatAroundNewYear() {
        assertEquals(Outfit.NONE, season(2026, 12, 30))
        assertEquals(Outfit.PARTY_HAT, season(2026, 12, 31))
        assertEquals(Outfit.PARTY_HAT, season(2027, 1, 1))
        assertEquals(Outfit.PARTY_HAT, season(2027, 1, 2))
        assertEquals(Outfit.NONE, season(2027, 1, 3))
    }

    @Test fun sunglassesFromJuneTwentyFirstToAugustThirtyFirst() {
        assertEquals(Outfit.NONE, season(2026, 6, 20))
        assertEquals(Outfit.SUNGLASSES, season(2026, 6, 21))
        assertEquals(Outfit.SUNGLASSES, season(2026, 8, 31))
        assertEquals(Outfit.NONE, season(2026, 9, 1))
    }

    @Test fun easterDatesAreRight() {
        assertEquals(4 to 5, Wardrobe.easterDate(2026))
        assertEquals(3 to 31, Wardrobe.easterDate(2024))
        assertEquals(4 to 20, Wardrobe.easterDate(2025))
        assertEquals(4 to 9, Wardrobe.easterDate(2023))
    }

    @Test fun bunnyEarsTwoDaysBeforeEasterToTheDayAfter() {
        // Easter 2026 is April 5.
        assertEquals(Outfit.NONE, season(2026, 4, 2))
        assertEquals(Outfit.BUNNY_EARS, season(2026, 4, 3))
        assertEquals(Outfit.BUNNY_EARS, season(2026, 4, 5))
        assertEquals(Outfit.BUNNY_EARS, season(2026, 4, 6))
        assertEquals(Outfit.NONE, season(2026, 4, 7))
    }

    @Test fun unknownStoredValuesMeanAuto() {
        assertEquals("auto", Wardrobe.parse(null))
        assertEquals("auto", Wardrobe.parse("topHat"))
        assertEquals("auto", Wardrobe.parse(""))
        for (s in Wardrobe.SELECTIONS) assertEquals(s, Wardrobe.parse(s))
    }

    @Test fun autoFollowsTheSeasonAndAnythingElseIsWornAsChosen() {
        assertEquals(Outfit.WITCH_HAT, Wardrobe.resolve("auto", LocalDate.of(2026, 10, 10)))
        assertEquals(Outfit.CROWN, Wardrobe.resolve("crown", LocalDate.of(2026, 10, 10)))
        assertEquals(Outfit.NONE, Wardrobe.resolve("none", LocalDate.of(2026, 10, 10)))
    }

    @Test fun theListsAreTheSameAsOnTheComputer() {
        val ts = ReferenceFiles.read("windows/src/mochi/wardrobe.ts")
        val body = ts.substringAfter("export const OUTFIT_SELECTIONS = [").substringBefore("] as const")
        val ids = Regex("\"(\\w+)\"").findAll(body).map { it.groupValues[1] }.toList()
        assertEquals(ids, Wardrobe.SELECTIONS)
        assertEquals(Wardrobe.SELECTIONS.toSet(), Wardrobe.LABELS.keys)
        // Every outfit of the drawing code has a stored id, and every stored id but "auto" is an outfit.
        assertEquals(Wardrobe.SELECTIONS.filter { it != "auto" }.toSet(), Outfit.entries.map { it.id }.toSet())
        for (id in ids) if (id != "auto") assertTrue(Wardrobe.outfitOf(id).id == id)
        for ((id, label) in Wardrobe.LABELS) assertTrue("$id: $label", ts.contains("N_(\"$label\")"))
    }
}
