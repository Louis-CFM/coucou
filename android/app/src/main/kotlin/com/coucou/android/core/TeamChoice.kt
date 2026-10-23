package com.coucou.android.core

import com.coucou.android.mochi.BotState

/**
 * The Team widget: the user picks which agents it shows (up to [MAX]), one choice per widget. This is the pure part: what can be picked, how
 * a choice is stored and read back (a short comma list that only ever holds ids of the catalog), and which rows the widget draws.
 *
 * An agent that is picked and not running is still shown, as "Not running", so the widget keeps its shape. With nothing picked (the widget was
 * added without opening the choice screen) it shows the busiest agents, like the List.
 */
object TeamChoice {
    /** The most agents one Team widget shows (two rows of two). */
    const val MAX = 4

    /** What can be picked: the agents and workspace tools of the catalog, never an AI provider or a service. */
    val candidates: List<PillDefinition> = Pills.catalog.filter { it.category == PillCategory.WORKSPACE || it.category == PillCategory.AGENT }

    private val ids: Set<String> = candidates.map { it.id }.toSet()

    /** The name the picker and the widget use for an agent that is not running (the Claude Code hook arrives on the VS Code pill). */
    fun nameOf(id: String): String =
        if (id == Pills.DEFAULT_MAIN_PILL) Texts.t("widget_sample_claude", "Claude Code") else Pills.byId(id)?.name ?: id

    /** The choice as it is stored: ids in the user's order, nothing else. */
    fun encode(chosen: List<String>): String = clean(chosen).joinToString(",")

    /** The choice read back. Anything that is not an id of [candidates] (a stale value, a hand-edited file) is dropped, and a repeat too. */
    fun decode(raw: String?): List<String> = clean(raw?.split(',').orEmpty())

    private fun clean(list: List<String>): List<String> = list.map { it.trim() }.filter { it in ids }.distinct().take(MAX)

    /** Adds [id] at the end if it is not picked and there is room; removes it if it is. */
    fun toggle(chosen: List<String>, id: String): List<String> = when {
        id !in ids -> clean(chosen)
        id in chosen -> clean(chosen).filter { it != id }
        else -> clean(chosen + id)
    }

    /** True when [id] can still be added (there is room), or is already picked and can be removed. */
    fun canToggle(chosen: List<String>, id: String): Boolean = id in ids && (id in chosen || clean(chosen).size < MAX)

    /**
     * The rows to draw. Not connected: none (the widget shows its empty state). Connected: the picked agents in the picked order, each as it runs
     * or as [notRunning]; with nothing picked, the first [MAX] of [roster] (already most urgent first).
     */
    fun rows(connected: Boolean, roster: List<WidgetTile>, chosen: List<String>, notRunning: String): List<WidgetTile> {
        if (!connected) return emptyList()
        val picked = clean(chosen)
        if (picked.isEmpty()) return roster.take(MAX)
        return picked.map { id ->
            roster.firstOrNull { it.pillId == id }
                ?: WidgetTile(id, nameOf(id), BotState.IDLE, notRunning, WidgetData.parse(Pills.byId(id)?.colorHex) ?: WidgetTone.IDLE.argb)
        }
    }

    /** The look of the whole widget: orange if any shown agent waits for you, else the most urgent shown tone, else the calm one. */
    fun look(connected: Boolean, rows: List<WidgetTile>): WidgetTone = when {
        !connected -> WidgetTone.MUTED
        rows.any { it.tone == WidgetTone.ATTENTION } -> WidgetTone.ATTENTION
        rows.any { it.tone == WidgetTone.TROUBLE } -> WidgetTone.TROUBLE
        rows.any { it.tone == WidgetTone.WORKING } -> WidgetTone.WORKING
        rows.any { it.tone == WidgetTone.DONE } -> WidgetTone.DONE
        else -> WidgetTone.IDLE
    }

    /** What TalkBack says for the whole card: each shown agent with its state, or the one clear line when there is none. */
    fun spoken(rows: List<WidgetTile>, emptyLine: String): String =
        if (rows.isEmpty()) emptyLine else rows.joinToString(". ") { WidgetSpoken.tile(it) }
}
