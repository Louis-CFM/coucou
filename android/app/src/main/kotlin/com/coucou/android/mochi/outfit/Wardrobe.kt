package com.coucou.android.mochi.outfit

import java.time.LocalDate
import java.time.temporal.ChronoUnit

/**
 * Mochi's wardrobe logic, a port of windows/src/mochi/wardrobe.ts: what is stored ("auto" or an outfit),
 * and which outfit "auto" means on a given day. The raw values are the Mac's and the PC's: keep them stable.
 */
object Wardrobe {
    /** Order of the wardrobe: "auto" (dress for the season), "none", then the outfits. */
    val SELECTIONS: List<String> = listOf(
        "auto", "none", "partyHat", "beanie", "crown", "sunglasses", "roundGlasses",
        "bow", "scarf", "witchHat", "pumpkin", "santaHat", "bunnyEars",
    )
    const val AUTO = "auto"
    const val DEFAULT = AUTO
    /** The phone's own choice when it does not pick an outfit itself: wear what the computer says. */
    const val FOLLOW = "computer"

    /** A phone-local choice read from the preferences: "computer", "auto" or an outfit; anything else follows the computer. */
    fun parseLocal(raw: String?): String = if (raw != null && (raw == FOLLOW || raw in SELECTIONS)) raw else FOLLOW

    /** What is worn, as a selection: the phone's own choice, or the computer's when the phone follows it. */
    fun choose(local: String, computer: String): String = if (local == FOLLOW) parse(computer) else parseLocal(local)

    /** The names shown to the user (the PC's English names). */
    val LABELS: Map<String, String> = mapOf(
        "auto" to "Auto (seasons)", "none" to "None", "partyHat" to "Party hat", "beanie" to "Beanie", "crown" to "Crown",
        "sunglasses" to "Sunglasses", "roundGlasses" to "Round glasses", "bow" to "Bow", "scarf" to "Scarf",
        "witchHat" to "Witch hat", "pumpkin" to "Pumpkin", "santaHat" to "Santa hat", "bunnyEars" to "Bunny ears",
    )

    /** A stored value, or one received from the computer, to a selection; anything unknown means "auto" (like the Mac). */
    fun parse(raw: String?): String = if (raw != null && raw in SELECTIONS) raw else DEFAULT

    fun outfitOf(id: String): Outfit = Outfit.entries.firstOrNull { it.id == id } ?: Outfit.NONE

    /** Easter Sunday of [year] (Meeus/Jones/Butcher) as month 1..12 and day. */
    fun easterDate(year: Int): Pair<Int, Int> {
        val a = year % 19
        val b = year / 100
        val c = year % 100
        val d = b / 4
        val e = b % 4
        val f = (b + 8) / 25
        val g = (b - f + 1) / 3
        val h = (19 * a + b - d - g + 15) % 30
        val i = c / 4
        val k = c % 4
        val l = (32 + 2 * e + 2 * i - h - k) % 7
        val m = (a + 11 * h + 22 * l) / 451
        val month = (h + l - 7 * m + 114) / 31
        val day = (h + l - 7 * m + 114) % 31 + 1
        return month to day
    }

    /** The seasonal outfit for [date] in the user's calendar. Priority: party hat, Santa hat, witch hat, bunny ears, sunglasses, none. */
    fun seasonal(date: LocalDate): Outfit {
        val day = date.dayOfMonth
        val month = date.monthValue
        val year = date.year
        if ((month == 12 && day == 31) || (month == 1 && day <= 2)) return Outfit.PARTY_HAT // Dec 31 - Jan 2
        if (month == 12 && day <= 26) return Outfit.SANTA_HAT // Dec 1-26
        if (month == 10 || (month == 11 && day == 1)) return Outfit.WITCH_HAT // Oct 1 - Nov 1
        // Two days before Easter to the day after.
        val (em, ed) = easterDate(year)
        val delta = ChronoUnit.DAYS.between(LocalDate.of(year, em, ed), date)
        if (delta in -2..1) return Outfit.BUNNY_EARS
        if ((month == 6 && day >= 21) || month == 7 || month == 8) return Outfit.SUNGLASSES // Jun 21 - Aug 31
        return Outfit.NONE
    }

    /** "auto" means the season's outfit; anything else is worn as chosen. */
    fun resolve(selection: String, date: LocalDate): Outfit = if (selection == AUTO) seasonal(date) else outfitOf(selection)
}
