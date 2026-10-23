package com.coucou.android.core

import java.util.Locale

/**
 * The words that the pure rules produce ("Running a command", "2 agents are working", "resets at 14:30") go through here, so they follow the
 * app's language like every other string. The app installs a [Source] that looks the key up in the string resources; with none (the unit
 * tests, which are English) the English written next to the key is used. A test checks that each English text in the code is the one in
 * i18n/app-strings.json, so the two can never differ.
 */
object Texts {
    /** Where translated texts come from: the string resources of the app, in the language chosen. */
    interface Source {
        fun string(key: String): String?
        /** The text for [count] in the language's plural rule; null when there is none. */
        fun plural(key: String, count: Int): String?
    }

    @Volatile var source: Source? = null

    /** The text of [key], formatted with [args] (positional, "%1$s"); [english] when there is no translation. */
    fun t(key: String, english: String, vararg args: Any?): String = format(source?.string(key) ?: english, args)

    /**
     * A text that depends on a number: [one] and [other] are the English forms ("%1$d request", "%1$d requests"); the count is the first
     * argument, [extra] come after it. In other languages the plural rule of the language picks the form.
     */
    fun n(key: String, count: Int, one: String, other: String, vararg extra: Any?): String {
        val template = source?.plural(key, count) ?: if (count == 1) one else other
        return format(template, arrayOf<Any?>(count, *extra))
    }

    private fun format(template: String, args: Array<out Any?>): String =
        if (args.isEmpty()) template else String.format(Locale.getDefault(), template, *args)
}
