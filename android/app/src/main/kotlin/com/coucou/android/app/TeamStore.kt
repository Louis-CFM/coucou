package com.coucou.android.app

import android.content.Context
import com.coucou.android.core.TeamChoice

/**
 * Which agents each Team widget shows: one choice per widget id, in this app's private preferences. It stays on the phone (no backup, nothing
 * sends it anywhere), and a choice goes away with its widget ([remove], called when the widget is deleted).
 */
class TeamStore(context: Context) {
    private val prefs = context.getSharedPreferences("widget_team", Context.MODE_PRIVATE)

    /** The agents picked for [widgetId], in order; empty when nothing was picked (the widget then shows the busiest ones). */
    fun get(widgetId: Int): List<String> = TeamChoice.decode(prefs.getString(key(widgetId), null))

    fun set(widgetId: Int, chosen: List<String>) {
        prefs.edit().putString(key(widgetId), TeamChoice.encode(chosen)).apply()
    }

    fun remove(widgetIds: IntArray) {
        if (widgetIds.isEmpty()) return
        prefs.edit().apply { widgetIds.forEach { remove(key(it)) } }.apply()
    }

    private fun key(widgetId: Int) = "w$widgetId"
}
