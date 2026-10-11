package com.coucou.android.core

import com.coucou.android.link.SessionInfo
import com.coucou.android.mochi.BotState
import com.coucou.android.mochi.Rgb

/**
 * What the Home screen shows, like the PC's Home panel: one agent card for the agent that matters
 * most (or the one the user tapped), and a grid of the others. Pure, so it is unit-tested.
 */
object HomePanel {
    private val URGENCY = listOf(
        BotState.APPROVAL, BotState.QUESTION, BotState.ERROR, BotState.RATELIMIT, BotState.DIZZY,
        BotState.WORKING, BotState.SEARCHING, BotState.THINKING, BotState.FINISHED, BotState.SLEEPING, BotState.IDLE,
    )

    /** The tapped agent if it is still there, else the one that needs the user most (the first on a tie). */
    fun focus(sessions: List<SessionInfo>, selectedPillId: String?): SessionInfo? =
        sessions.firstOrNull { it.pillId == selectedPillId }
            ?: sessions.minByOrNull { URGENCY.indexOf(it.state).let { i -> if (i < 0) URGENCY.size else i } }

    /** The others, in the order the desktop sent them. */
    fun others(sessions: List<SessionInfo>, focus: SessionInfo?): List<SessionInfo> =
        sessions.filter { it.pillId != focus?.pillId }

    /**
     * The one link on the agent card: answer a waiting request first, else pair when there is no
     * computer yet, else nothing (Settings has its own button at the top).
     */
    enum class Link { NONE, APPROVAL, PAIR }

    fun link(paired: Boolean, demo: Boolean, hasApproval: Boolean): Link = when {
        hasApproval -> Link.APPROVAL
        !paired && !demo -> Link.PAIR
        else -> Link.NONE
    }

    /** There is something to open: steps, a last message or a project name (only with the "details" capability). */
    fun hasDetails(s: SessionInfo): Boolean = s.steps.isNotEmpty() || !s.finalLine.isNullOrBlank() || s.project != null || s.files.isNotEmpty()

    /** The colour of an agent: the one the user gave its pill on the computer, else the catalog's. */
    fun colorHex(s: SessionInfo): String? = s.color ?: Pills.byId(s.pillId)?.colorHex

    /** Newest first, as the detail screen lists them. */
    fun stepsNewestFirst(s: SessionInfo): List<String> = s.steps.asReversed()

    /** "#8AB4F8" to a colour for a mini Mochi's body; a malformed value gives null (the default body). */
    fun rgb(hex: String): Rgb? {
        val h = hex.trim().removePrefix("#")
        if (h.length != 6) return null
        val v = h.toIntOrNull(16) ?: return null
        return Rgb(((v shr 16) and 0xFF) / 255.0, ((v shr 8) and 0xFF) / 255.0, (v and 0xFF) / 255.0)
    }
}
