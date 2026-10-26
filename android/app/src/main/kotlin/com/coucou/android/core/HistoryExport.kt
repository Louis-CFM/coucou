package com.coucou.android.core

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * Search and "Export as text" for the phone's own list of decisions. Both work on the wording the list already shows ("You allowed Claude
 * Code to run a command"), so the command itself, which the phone also keeps for the sheet, is never searched and never exported. Nothing here
 * touches the network: the text goes to Android's share sheet, where the user picks where it goes.
 */
object HistoryExport {
    /** A search longer than this is cut: nobody types more, and nothing downstream has to cope with a huge string. */
    const val MAX_QUERY = 100

    /** The decision as the list says it. */
    fun label(d: Decision): String = HomeText.decision(d.allowed, d.agent, d.tool)

    /** The decisions whose wording or agent contains every word of [query] (case and accents as typed); a blank query keeps them all. */
    fun filter(list: List<Decision>, query: String): List<Decision> {
        val words = query.take(MAX_QUERY).trim().lowercase().split(Regex("\\s+")).filter { it.isNotEmpty() }
        if (words.isEmpty()) return list
        return list.filter { d ->
            val hay = (label(d) + " " + d.agent).lowercase()
            words.all { it in hay }
        }
    }

    private val STAMP: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")

    /** One line per decision, newest first: "2026-10-14 09:30  You allowed Claude Code to run a command". */
    fun text(list: List<Decision>, header: String, zone: ZoneId): String =
        (listOf(header, "") + list.map { STAMP.format(Instant.ofEpochMilli(it.atMs).atZone(zone)) + "  " + label(it) }).joinToString("\n")
}
