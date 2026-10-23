package com.coucou.android.app

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.view.View
import android.widget.RemoteViews
import com.coucou.android.R
import com.coucou.android.core.TeamChoice
import com.coucou.android.core.WidgetContent
import com.coucou.android.core.WidgetSpoken

/**
 * The Team widget: up to four agents the user picked (a choice screen opens when it is added and from its long-press menu), two by two,
 * each with Mochi's small face in its state, its name and a state word. Drawn by [WidgetHub] when something changes (updatePeriodMillis = 0).
 * A tap on an agent that runs opens it; a tap on one that does not, or anywhere else, opens the app. It only opens things: a request waits
 * for you in the app, behind the fingerprint.
 */
class TeamWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) =
        WidgetHub.refreshEach(context, manager, ids) { c, w, id -> views(c, w, id) }

    override fun onDeleted(context: Context, ids: IntArray) {
        TeamStore(context).remove(ids)
    }

    companion object {
        private val CELLS = listOf(
            Cell(R.id.team_cell0, R.id.team_face0, R.id.team_name0, R.id.team_dot0, R.id.team_state0),
            Cell(R.id.team_cell1, R.id.team_face1, R.id.team_name1, R.id.team_dot1, R.id.team_state1),
            Cell(R.id.team_cell2, R.id.team_face2, R.id.team_name2, R.id.team_dot2, R.id.team_state2),
            Cell(R.id.team_cell3, R.id.team_face3, R.id.team_name3, R.id.team_dot3, R.id.team_state3),
        )

        private class Cell(val cell: Int, val face: Int, val name: Int, val dot: Int, val state: Int)

        fun views(context: Context, c: WidgetContent, widgetId: Int): RemoteViews =
            render(context, c, TeamStore(context).get(widgetId))

        private fun render(context: Context, c: WidgetContent, chosen: List<String>): RemoteViews {
            val v = RemoteViews(context.packageName, R.layout.widget_team)
            val rows = TeamChoice.rows(c.connected, c.roster, chosen, context.getString(R.string.widget_team_not_running))
            val look = TeamChoice.look(c.connected, rows)
            WidgetHub.paint(v, R.id.team_root, R.id.team_tint, look)
            v.setOnClickPendingIntent(R.id.team_root, WidgetHub.openApp(context, WidgetHub.CODE_TEAM + 8))
            val said = TeamChoice.spoken(rows, c.emptyLine.orEmpty())
            v.setContentDescription(R.id.team_root, said)

            if (rows.isEmpty()) {
                // Nothing to show: the computer is not there, or nothing runs. The empty state fills the card.
                v.setViewVisibility(R.id.team_grid, View.GONE)
                v.setViewVisibility(R.id.team_empty, View.VISIBLE)
                v.setImageViewBitmap(R.id.team_empty_face, MochiBitmap.of(c.mood, WidgetHub.px(context, 64), glow = true, tone = look))
                v.setContentDescription(R.id.team_empty_face, context.getString(R.string.widget_mochi_description, WidgetSpoken.mood(c.mood)))
                v.setImageViewResource(R.id.team_empty_icon, if (c.connected) R.drawable.widget_dot else R.drawable.ic_widget_offline)
                v.setInt(R.id.team_empty_icon, "setColorFilter", look.argb)
                v.setTextViewText(R.id.team_empty_title, c.headline)
                v.setTextViewText(R.id.team_empty_line, c.emptyLine.orEmpty())
                return v
            }

            v.setViewVisibility(R.id.team_empty, View.GONE)
            v.setViewVisibility(R.id.team_grid, View.VISIBLE)
            v.setViewVisibility(R.id.team_row0, View.VISIBLE)
            v.setViewVisibility(R.id.team_row1, if (rows.size > 2) View.VISIBLE else View.GONE)
            val face = WidgetHub.px(context, 36)
            CELLS.forEachIndexed { i, cell ->
                val tile = rows.getOrNull(i)
                if (tile == null) {
                    v.setViewVisibility(cell.cell, View.GONE)
                    return@forEachIndexed
                }
                v.setViewVisibility(cell.cell, View.VISIBLE)
                v.setImageViewBitmap(cell.face, MochiBitmap.of(tile.state, face))
                v.setTextViewText(cell.name, tile.name)
                v.setTextViewText(cell.state, tile.stateWord)
                v.setInt(cell.dot, "setColorFilter", tile.tone.argb)
                v.setContentDescription(cell.cell, WidgetSpoken.tile(tile))
                val runs = c.roster.any { it.pillId == tile.pillId }
                v.setOnClickPendingIntent(
                    cell.cell,
                    if (runs) WidgetHub.openSession(context, WidgetHub.CODE_TEAM + i, tile.pillId) else WidgetHub.openApp(context, WidgetHub.CODE_TEAM + 4 + i),
                )
            }
            return v
        }
    }
}
