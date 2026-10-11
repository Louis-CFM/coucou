package com.coucou.android.core

import com.coucou.android.link.LinkState
import com.coucou.android.link.SessionInfo
import com.coucou.android.mochi.BotState

/** One agent in a glance: its name and one plain line. No command, no path, no answer text. */
data class GlanceLine(val agent: String, val text: String, val state: BotState)

/** How loud a glance is: picks the dot colour of the widget, the tile state and the notification accent. */
enum class GlanceTone(val argb: Int) {
    CALM(0xFF8E8E93.toInt()),
    OK(0xFF34C759.toInt()),
    BUSY(0xFF0A84FF.toInt()),
    ATTENTION(0xFFFF9F0A.toInt()),
    TROUBLE(0xFFFF453A.toInt()),
}

/**
 * What the small surfaces show without opening the app: the ongoing notification, the home-screen widget and the
 * quick-settings tile. One pure summary so the three always say the same thing. Only agent names and the plain-language
 * lines of [HomeText] go in: never a command, a path, a file name or a final answer, because a widget or a tile can be
 * seen without unlocking the phone.
 */
data class Glance(
    val headline: String,
    val detail: String,
    val tone: GlanceTone,
    val connected: Boolean,
    val lines: List<GlanceLine>,
    /** Requests and questions waiting for the user. */
    val waiting: Int,
)

object GlanceBuilder {
    const val MAX_LINES = 4
    private val BUSY = setOf(BotState.WORKING, BotState.THINKING, BotState.SEARCHING)
    private val TROUBLE = setOf(BotState.ERROR, BotState.RATELIMIT, BotState.DIZZY)

    /** Most urgent first; the same order as the Home list. */
    private val ORDER = listOf(
        BotState.APPROVAL, BotState.QUESTION, BotState.ERROR, BotState.RATELIMIT, BotState.DIZZY,
        BotState.WORKING, BotState.SEARCHING, BotState.THINKING, BotState.FINISHED, BotState.SLEEPING, BotState.IDLE,
    )

    fun build(
        paired: Boolean,
        link: LinkState,
        desktop: String?,
        sessions: List<SessionInfo>,
        approvals: Int,
        nameOf: (String) -> String,
    ): Glance {
        if (!paired) return Glance("Not paired", "Open Coucou to connect to your computer", GlanceTone.CALM, false, emptyList(), 0)
        if (link != LinkState.CONNECTED) {
            val connecting = link == LinkState.CONNECTING
            return Glance(
                if (connecting) "Connecting…" else "Not connected",
                if (connecting) "Reaching your computer" else "Coucou cannot reach your computer",
                GlanceTone.CALM, false, emptyList(), 0,
            )
        }
        val ranked = sessions.sortedBy { ORDER.indexOf(it.state).let { i -> if (i < 0) ORDER.size else i } }
        val lines = ranked.take(MAX_LINES).map { GlanceLine(nameOf(it.pillId), lineOf(it), it.state) }
        val questions = sessions.count { it.state == BotState.QUESTION }
        val waiting = approvals + questions
        val busy = sessions.count { it.state in BUSY }
        val trouble = sessions.count { it.state in TROUBLE }
        val where = desktop?.takeIf { it.isNotBlank() }
        return when {
            approvals > 0 -> Glance(
                "Waiting for you",
                if (approvals == 1) "1 request to approve" else "$approvals requests to approve",
                GlanceTone.ATTENTION, true, lines, waiting,
            )
            questions > 0 -> Glance(
                "Waiting for your answer",
                if (questions == 1) "1 question from an agent" else "$questions questions from agents",
                GlanceTone.ATTENTION, true, lines, waiting,
            )
            trouble > 0 -> Glance(
                "An agent needs a look",
                if (trouble == 1) "1 agent stopped" else "$trouble agents stopped",
                GlanceTone.TROUBLE, true, lines, 0,
            )
            busy > 0 -> Glance(
                if (busy == 1) "${nameOf(ranked.first { it.state in BUSY }.pillId)} is working" else "$busy agents are working",
                where?.let { "On $it" } ?: "Working",
                GlanceTone.BUSY, true, lines, 0,
            )
            sessions.any { it.state == BotState.FINISHED } -> Glance(
                "All done", where?.let { "On $it" } ?: "Finished", GlanceTone.OK, true, lines, 0,
            )
            else -> Glance("Connected", where?.let { "To $it" } ?: "Nothing is running", GlanceTone.OK, true, lines, 0)
        }
    }

    /** The plain line of a session: its state in a few words, never its step text or answer (those stay in the app). */
    private fun lineOf(s: SessionInfo): String = when (s.state) {
        BotState.APPROVAL -> "Waiting for your approval"
        BotState.QUESTION -> "Has a question"
        BotState.ERROR -> "Stopped on an error"
        BotState.RATELIMIT -> "Hit a limit"
        BotState.DIZZY -> "Needs a look"
        BotState.FINISHED -> "Finished"
        BotState.SLEEPING, BotState.IDLE -> "Idle"
        BotState.THINKING -> "Thinking"
        BotState.SEARCHING -> "Searching"
        else -> "Working" // never the step text: it can hold a file name or a command
    }
}
