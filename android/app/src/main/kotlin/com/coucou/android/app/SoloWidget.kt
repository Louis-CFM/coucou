package com.coucou.android.app

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.util.SizeF
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews
import com.coucou.android.R
import com.coucou.android.core.WidgetContent
import com.coucou.android.core.WidgetSpoken

/**
 * The Solo widget: Mochi with a glow in the state's colour, the name of the most urgent agent with a dot and one state
 * word. Drawn by [WidgetHub] when something changes (updatePeriodMillis = 0). A tap opens that agent, or the app when none
 * is running. It only opens things: nothing is changed from here.
 */
class SoloWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) =
        WidgetHub.refresh(context, manager, ids) { c, w -> views(c, w) }

    companion object {
        private val MEDIUM_AT = SizeF(100f, 100f)
        private val LARGE_AT = SizeF(200f, 200f)

        fun views(context: Context, c: WidgetContent): RemoteViews =
            WidgetHub.responsive(MEDIUM_AT, LARGE_AT) { size -> render(context, c, size) }

        private fun render(context: Context, c: WidgetContent, size: WidgetHub.Size): RemoteViews {
            val v = RemoteViews(context.packageName, R.layout.widget_solo)
            WidgetHub.paint(v, R.id.solo_root, R.id.solo_tint, c.look)
            val top = c.top
            val large = size == WidgetHub.Size.LARGE
            val small = size == WidgetHub.Size.SMALL

            v.setImageViewBitmap(R.id.solo_mochi, MochiBitmap.of(c.mood, WidgetHub.px(context, if (large) 150 else if (small) 72 else 104), glow = true, tone = c.look))
            val word = top?.stateWord ?: c.headline
            v.setContentDescription(R.id.solo_mochi, context.getString(R.string.widget_mochi_description, word.lowercase()))
            // The tapped card says who and what, in one sentence.
            v.setContentDescription(R.id.solo_root, WidgetSpoken.top(c))

            if (top != null) {
                v.setViewVisibility(R.id.solo_name_row, View.VISIBLE)
                v.setViewVisibility(R.id.solo_note_row, View.GONE)
                v.setTextViewText(R.id.solo_name, top.name)
                v.setInt(R.id.solo_dot, "setColorFilter", top.tone.argb)
                v.setTextViewText(R.id.solo_state, top.stateWord)
            } else {
                // Nothing to list: the headline with an icon, and the one clear line under it.
                v.setViewVisibility(R.id.solo_name_row, View.GONE)
                v.setViewVisibility(R.id.solo_note_row, View.VISIBLE)
                v.setTextViewText(R.id.solo_note, c.headline)
                v.setImageViewResource(R.id.solo_note_icon, if (c.connected) R.drawable.widget_dot else R.drawable.ic_widget_offline)
                v.setInt(R.id.solo_note_icon, "setColorFilter", c.look.argb)
                v.setTextViewText(R.id.solo_state, c.emptyLine.orEmpty())
            }
            v.setViewVisibility(R.id.solo_state, if (small && top != null) View.GONE else View.VISIBLE)
            v.setTextViewTextSize(R.id.solo_name, TypedValue.COMPLEX_UNIT_SP, if (large) 20f else 16f)
            v.setTextViewTextSize(R.id.solo_state, TypedValue.COMPLEX_UNIT_SP, if (large) 15f else 13f)

            if (c.waiting > 0) {
                v.setTextViewText(R.id.solo_badge, c.waiting.toString())
                v.setContentDescription(R.id.solo_badge, context.getString(R.string.widget_badge_description, c.waiting))
                v.setViewVisibility(R.id.solo_badge, View.VISIBLE)
            } else {
                v.setViewVisibility(R.id.solo_badge, View.GONE)
            }
            v.setOnClickPendingIntent(
                R.id.solo_root,
                if (top != null) WidgetHub.openSession(context, WidgetHub.CODE_SOLO, top.pillId) else WidgetHub.openApp(context, WidgetHub.CODE_SOLO),
            )
            return v
        }
    }
}
