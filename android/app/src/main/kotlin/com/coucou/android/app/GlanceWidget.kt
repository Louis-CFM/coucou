package com.coucou.android.app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import com.coucou.android.MainActivity
import com.coucou.android.R
import com.coucou.android.core.Glance

/**
 * The home-screen widget: the same short summary as the notification and the tile ([Glance]), drawn with plain
 * RemoteViews. It never updates on a timer (updatePeriodMillis = 0): the app pushes a new picture when something
 * changes, so it costs nothing while nothing happens. A tap opens Coucou.
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

        private fun views(context: Context, g: Glance): RemoteViews {
            val v = RemoteViews(context.packageName, R.layout.widget_glance)
            v.setTextViewText(R.id.widget_headline, g.headline)
            v.setTextViewText(R.id.widget_detail, g.detail)
            v.setTextColor(R.id.widget_dot, g.tone.argb)
            v.setTextViewText(R.id.widget_lines, g.lines.joinToString("\n") { "${it.agent}: ${it.text}" })
            val open = Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            v.setOnClickPendingIntent(
                R.id.widget_root,
                PendingIntent.getActivity(context, 0, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE),
            )
            return v
        }
    }
}
