package com.coucou.android.core

/**
 * What TalkBack says for the things that are drawn rather than written (a state dot, a Mochi, a badge), so the state of an agent
 * is never only a colour. Pure: the words come from the string resources, this only joins them in one fixed shape.
 */
object SpokenLabels {
    private fun lowerFirst(s: String) = s.replaceFirstChar { it.lowercaseChar() }

    /** "Claude Code, waiting for your OK. Editing files": the name, the state in words, then the line when it says something more. */
    fun agent(name: String, state: String, line: String?): String {
        val who = name.trim()
        val st = state.trim()
        val extra = line?.trim().orEmpty().takeIf { it.isNotEmpty() && !it.equals(st, ignoreCase = true) }
        val head = when {
            who.isEmpty() -> st
            st.isEmpty() -> who
            else -> "$who, ${lowerFirst(st)}"
        }
        return if (extra == null) head else "$head. $extra"
    }

    /** "Approval needed: Claude Code wants to run a command". [wants] is the sheet's own sentence ("Wants to run a command"). */
    fun approval(title: String, name: String, wants: String): String {
        val who = name.trim()
        val sentence = if (who.isEmpty()) wants.trim() else "$who ${lowerFirst(wants.trim())}"
        return "${title.trim()}: $sentence"
    }

    /** A tab that carries the alert dot says why: "Home, a request is waiting". */
    fun tab(label: String, alert: Boolean, alertText: String): String = if (alert) alertText else label
}
