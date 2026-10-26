package com.coucou.android.app

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.util.SizeF
import android.view.View
import android.widget.RemoteViews
import com.coucou.android.R
import com.coucou.android.core.WidgetSpoken
import com.coucou.android.core.Glance
import com.coucou.android.core.WidgetTone
import com.coucou.android.core.look
import com.coucou.android.core.mood

/**
 * The home-screen summary widget (3x2): the same short summary as the notification and the tile ([Glance]: its text and counts
 * are unchanged), on the shared card with a gradient in the colour of the state. A small Mochi in the state of the most urgent
 * agent sits on the left; on the right are the headline, a badge for what waits for you and up to three short lines, each with a
 * dot in the state's tone. It never updates on a timer (updatePeriodMillis = 0): the app pushes a new picture when something
 * changes, so it costs nothing while nothing happens. A tap anywhere opens Coucou; there is no button here.
 */
class GlanceWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val model = (context.applicationContext as CoucouApp).model
        val views = views(context, model.glance())
        for (id in ids) runCatching { manager.updateAppWidget(id, views) }
    }

    companion object {
        /** Pushes [glance] to every widget of this app on the home screen (none: nothing happens). */
        fun update(context: Context, glance: Glance) {
            runCatching {
                val manager = AppWidgetManager.getInstance(context)
                val ids = manager.getAppWidgetIds(ComponentName(context, GlanceWidget::class.java))
                if (ids.isEmpty()) return
                val views = views(context, glance)
                for (id in ids) manager.updateAppWidget(id, views)
            }
        }

        // Height in dp: from 100 two lines under the headline, from 150 the detail line and three lines; below, one line.
        private val MEDIUM_AT = SizeF(0f, 100f)
        private val LARGE_AT = SizeF(0f, 150f)

        private class Row(val row: Int, val dot: Int, val name: Int, val text: Int)

        private val ROWS = listOf(
            Row(R.id.glance_row0, R.id.glance_dot0, R.id.glance_name0, R.id.glance_text0),
            Row(R.id.glance_row1, R.id.glance_dot1, R.id.glance_name1, R.id.glance_text1),
            Row(R.id.glance_row2, R.id.glance_dot2, R.id.glance_name2, R.id.glance_text2),
        )

        private fun views(context: Context, g: Glance): RemoteViews =
            WidgetHub.responsive(MEDIUM_AT, LARGE_AT) { size -> render(context, g, size) }

        private fun render(context: Context, g: Glance, size: WidgetHub.Size): RemoteViews {
            val v = RemoteViews(context.packageName, R.layout.widget_glance)
            val tone = g.look()
            WidgetHub.paint(v, R.id.widget_root, R.id.glance_tint, tone)

            val mood = g.mood()
            v.setImageViewBitmap(R.id.glance_mochi, MochiBitmap.of(mood, WidgetHub.px(context, 64), glow = true, tone = tone))
            v.setContentDescription(R.id.glance_mochi, context.getString(R.string.widget_mochi_description, WidgetSpoken.mood(mood)))

            v.setViewVisibility(R.id.glance_offline, if (g.connected) View.GONE else View.VISIBLE)
            v.setTextViewText(R.id.glance_headline, g.headline)
            if (g.waiting > 0) {
                v.setTextViewText(R.id.glance_badge, g.waiting.toString())
                v.setContentDescription(R.id.glance_badge, context.getString(R.string.widget_badge_description, g.waiting))
                v.setViewVisibility(R.id.glance_badge, View.VISIBLE)
            } else {
                v.setViewVisibility(R.id.glance_badge, View.GONE)
            }

            val rows = when (size) {
                WidgetHub.Size.SMALL -> 1
                WidgetHub.Size.MEDIUM -> 2
                WidgetHub.Size.LARGE -> ROWS.size
            }
            // The detail line says why there is nothing to list, or, with room to spare, adds to the headline.
            v.setTextViewText(R.id.glance_detail, g.detail)
            v.setViewVisibility(R.id.glance_detail, if (g.lines.isEmpty() || size == WidgetHub.Size.LARGE) View.VISIBLE else View.GONE)
            ROWS.forEachIndexed { i, r ->
                val line = g.lines.getOrNull(i)
                if (line == null || i >= rows) {
                    v.setViewVisibility(r.row, View.GONE)
                    return@forEachIndexed
                }
                v.setViewVisibility(r.row, View.VISIBLE)
                v.setInt(r.dot, "setColorFilter", WidgetTone.of(line.state).argb)
                v.setTextViewText(r.name, line.agent)
                v.setTextViewText(r.text, line.text)
            }

            v.setContentDescription(R.id.widget_root, listOf(g.headline, g.detail).filter { it.isNotBlank() }.joinToString(". "))
            v.setOnClickPendingIntent(R.id.widget_root, WidgetHub.openApp(context, WidgetHub.CODE_GLANCE))
            return v
        }
    }
}
