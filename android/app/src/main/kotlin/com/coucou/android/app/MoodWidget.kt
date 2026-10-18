package com.coucou.android.app

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.view.View
import android.widget.RemoteViews
import com.coucou.android.R
import com.coucou.android.core.WidgetContent

/**
 * The Mochi Mood widget: only Mochi's face in the current state, with his glow. Drawn by [WidgetHub] when something changes
 * (updatePeriodMillis = 0). A tap opens the top agent, or the app. It only opens things.
 */
class MoodWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) =
        WidgetHub.refresh(context, manager, ids) { c, w -> views(c, w) }

    companion object {
        fun views(context: Context, c: WidgetContent): RemoteViews {
            val v = RemoteViews(context.packageName, R.layout.widget_mood)
            WidgetHub.paint(v, R.id.mood_root, R.id.mood_tint, c.look)
            v.setImageViewBitmap(R.id.mood_face, MochiBitmap.of(c.mood, WidgetHub.px(context, 64), glow = true, tone = c.look))
            v.setContentDescription(R.id.mood_face, context.getString(R.string.widget_mochi_description, (c.top?.stateWord ?: c.headline).lowercase()))
            v.setViewVisibility(R.id.mood_offline, if (c.connected) View.GONE else View.VISIBLE)
            val top = c.top
            v.setOnClickPendingIntent(
                R.id.mood_root,
                if (top != null) WidgetHub.openSession(context, WidgetHub.CODE_MOOD, top.pillId) else WidgetHub.openApp(context, WidgetHub.CODE_MOOD),
            )
            return v
        }
    }
}
