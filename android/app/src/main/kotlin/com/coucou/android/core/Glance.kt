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

    /** Where a state sits in the list, most urgent first; unknown states go last. */
    fun rank(state: BotState): Int = ORDER.indexOf(state).let { i -> if (i < 0) ORDER.size else i }

    fun build(
        paired: Boolean,
        link: LinkState,
        desktop: String?,
        sessions: List<SessionInfo>,
        approvals: Int,
        nameOf: (String) -> String,
    ): Glance {
        if (!paired) return Glance(Texts.t("glance_not_paired", "Not paired"), Texts.t("glance_not_paired_detail", "Open Coucou to connect to your computer"), GlanceTone.CALM, false, emptyList(), 0)
        if (link != LinkState.CONNECTED) {
            val connecting = link == LinkState.CONNECTING
            return Glance(
                if (connecting) Texts.t("status_connecting", "Connecting…") else Texts.t("status_not_connected", "Not connected"),
                if (connecting) Texts.t("glance_reaching", "Reaching your computer") else Texts.t("glance_cannot_reach", "Coucou cannot reach your computer"),
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
                Texts.t("glance_waiting_you", "Waiting for you"),
                Texts.n("glance_requests", approvals, "%1\$d request to approve", "%1\$d requests to approve"),
                GlanceTone.ATTENTION, true, lines, waiting,
            )
            questions > 0 -> Glance(
                Texts.t("glance_waiting_answer", "Waiting for your answer"),
                Texts.n("glance_questions", questions, "%1\$d question from an agent", "%1\$d questions from agents"),
                GlanceTone.ATTENTION, true, lines, waiting,
            )
            trouble > 0 -> Glance(
                Texts.t("glance_needs_look", "An agent needs a look"),
                Texts.n("glance_stopped", trouble, "%1\$d agent stopped", "%1\$d agents stopped"),
                GlanceTone.TROUBLE, true, lines, 0,
            )
            busy > 0 -> Glance(
                if (busy == 1) Texts.t("glance_one_working", "%1\$s is working", nameOf(ranked.first { it.state in BUSY }.pillId))
                else Texts.n("glance_working_many", busy, "%1\$d agent is working", "%1\$d agents are working"),
                where?.let { Texts.t("glance_on", "On %1\$s", it) } ?: Texts.t("state_working", "Working"),
                GlanceTone.BUSY, true, lines, 0,
            )
            sessions.any { it.state == BotState.FINISHED } -> Glance(
                Texts.t("glance_all_done", "All done"), where?.let { Texts.t("glance_on", "On %1\$s", it) } ?: Texts.t("state_finished", "Finished"), GlanceTone.OK, true, lines, 0,
            )
            else -> Glance(Texts.t("status_connected", "Connected"), where?.let { Texts.t("glance_to", "To %1\$s", it) } ?: Texts.t("glance_nothing_running", "Nothing is running"), GlanceTone.OK, true, lines, 0)
        }
    }

    /** The plain line of a session: its state in a few words, never its step text or answer (those stay in the app). */
    fun lineOf(s: SessionInfo): String = when (s.state) {
        BotState.APPROVAL -> Texts.t("glance_line_approval", "Waiting for your approval")
        BotState.QUESTION -> Texts.t("notif_question", "Has a question")
        BotState.ERROR -> Texts.t("notif_error", "Stopped on an error")
        BotState.RATELIMIT -> Texts.t("glance_line_limit", "Hit a limit")
        BotState.DIZZY -> Texts.t("glance_line_dizzy", "Needs a look")
        BotState.FINISHED -> Texts.t("state_finished", "Finished")
        BotState.SLEEPING, BotState.IDLE -> Texts.t("glance_line_idle", "Idle")
        BotState.THINKING -> Texts.t("state_thinking", "Thinking")
        BotState.SEARCHING -> Texts.t("state_searching", "Searching")
        else -> Texts.t("state_working", "Working") // never the step text: it can hold a file name or a command
    }
}
