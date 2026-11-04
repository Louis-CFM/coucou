package com.coucou.android.core

import com.coucou.android.link.SessionInfo
import com.coucou.android.mochi.BotState

/** The words on Home: one plain line per agent, what you decided lately, how many are busy. Pure, so it is unit-tested. */
object HomeText {
    private val BUSY = setOf(BotState.WORKING, BotState.THINKING, BotState.SEARCHING)

    /**
     * The sentence under an agent's name: its last message once it has finished, otherwise what it is
     * doing in plain words ([ToolLabels]). Null when there is nothing to say; the screen then shows the state's name.
     */
    fun line(s: SessionInfo): String? {
        if (s.state == BotState.FINISHED) s.finalLine?.let { SafeText.prose(it) }?.takeIf { it.isNotEmpty() && it != "…" }?.let { return it }
        return ToolLabels.label(s.statusText).takeIf { it.isNotEmpty() }
    }

    /** "Allowed: edit files" or "Denied: run a command", for the Recent list. */
    fun recent(allowed: Boolean, tool: String): String =
        if (allowed) Texts.t("home_recent_allowed", "Allowed: %1\$s", ToolLabels.action(tool)) else Texts.t("home_recent_denied", "Denied: %1\$s", ToolLabels.action(tool))

    /** "You allowed Claude Code to run a command": a decision in a sentence, with no command and no path. */
    fun decision(allowed: Boolean, agent: String, tool: String): String {
        val who = agent.ifBlank { Texts.t("agent_an", "an agent") }
        return if (allowed) Texts.t("home_decision_allowed", "You allowed %1\$s to %2\$s", who, ToolLabels.action(tool))
        else Texts.t("home_decision_denied", "You denied %1\$s to %2\$s", who, ToolLabels.action(tool))
    }

    /** How many agents are busy (working, thinking or searching), for "2 running". */
    fun running(sessions: List<SessionInfo>): Int = sessions.count { it.state in BUSY }
}
