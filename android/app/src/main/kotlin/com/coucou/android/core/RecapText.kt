package com.coucou.android.core

import java.time.LocalDate
import java.time.format.TextStyle
import java.util.Locale

/** The words of the recap card, built from the numbers the computer sent. Pure, so each rule is a unit test. */
object RecapText {
    /** "5 h 40 min", "45 min", "2 h". */
    fun duration(minutes: Int): String {
        val m = minutes.coerceAtLeast(0)
        return when {
            m < 60 -> Texts.t("ago_minutes", "%1\$d min", m)
            m % 60 == 0 -> Texts.t("ago_hours", "%1\$d h", m / 60)
            else -> Texts.t("ago_hours_minutes", "%1\$d h %2\$d min", m / 60, m % 60)
        }
    }

    /** "5 Oct – 11 Oct" for the week that starts on [week] (`YYYY-MM-DD`); null if it is not a date. */
    fun weekLabel(week: String, locale: Locale = Locale.getDefault()): String? {
        val start = runCatching { LocalDate.parse(week) }.getOrNull() ?: return null
        val end = start.plusDays(6)
        fun f(d: LocalDate) = "${d.dayOfMonth} ${d.month.getDisplayName(TextStyle.SHORT, locale)}"
        return "${f(start)} – ${f(end)}"
    }

    /** "+900 −210". */
    fun lines(added: Int, removed: Int): String = "+$added −$removed"

    /** "20 allowed, 3 denied". */
    fun permissions(allowed: Int, denied: Int): String = Texts.t("recap_allowed_denied", "%1\$d allowed, %2\$d denied", allowed, denied)

    /** The label and value of each stat, in the order of the card. Optional ones are left out when the computer did not send them. */
    fun stats(r: com.coucou.android.link.Recap): List<Pair<String, String>> = buildList {
        add(Texts.t("recap_time", "Time with agents") to duration(r.minutes))
        add(Texts.t("recap_sessions", "Sessions") to r.sessions.toString())
        add(Texts.t("recap_files", "Files changed") to r.files.toString())
        add(Texts.t("recap_lines", "Lines") to lines(r.linesAdded, r.linesRemoved))
        add(Texts.t("recap_commands", "Commands run") to r.commands.toString())
        add(Texts.t("recap_permissions", "Permissions") to permissions(r.allowed, r.denied))
        r.topAgent?.let { add(Texts.t("recap_top_agent", "Most used") to it) }
        r.project?.let { add(Texts.t("recap_project", "Top project") to it) }
    }
}
