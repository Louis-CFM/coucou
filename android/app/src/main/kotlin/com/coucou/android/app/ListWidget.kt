package com.coucou.android.app

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.util.SizeF
import android.view.View
import android.widget.RemoteViews
import com.coucou.android.R
import com.coucou.android.core.WidgetContent

/**
 * The List widget: the headline with a badge, then one row per agent of at least 48dp (a bar in its own colour, Mochi's
 * face, its name, a state word and a dot in the state's tone). With no agent it is a centred empty state: Mochi asleep and
 * one clear line. Drawn by [WidgetHub] when something changes (updatePeriodMillis = 0). A tap on a row opens that agent; a
 * tap anywhere else opens the app. It only opens things: a request waits for you in the app, behind the fingerprint.
 */
class ListWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) =
        WidgetHub.refresh(context, manager, ids) { c, w -> views(c, w) }

    companion object {
        // Header 28dp + padding 20dp + 48dp per row: two rows fit 150dp, three 192dp, five 290dp.
        private val MEDIUM_AT = SizeF(0f, 192f)
        private val LARGE_AT = SizeF(0f, 290f)

        private val ROWS = listOf(
            Row(R.id.list_row0, R.id.list_stripe0, R.id.list_face0, R.id.list_name0, R.id.list_state0, R.id.list_dot0),
            Row(R.id.list_row1, R.id.list_stripe1, R.id.list_face1, R.id.list_name1, R.id.list_state1, R.id.list_dot1),
            Row(R.id.list_row2, R.id.list_stripe2, R.id.list_face2, R.id.list_name2, R.id.list_state2, R.id.list_dot2),
            Row(R.id.list_row3, R.id.list_stripe3, R.id.list_face3, R.id.list_name3, R.id.list_state3, R.id.list_dot3),
            Row(R.id.list_row4, R.id.list_stripe4, R.id.list_face4, R.id.list_name4, R.id.list_state4, R.id.list_dot4),
        )

        private class Row(val row: Int, val stripe: Int, val face: Int, val name: Int, val state: Int, val dot: Int)

        fun views(context: Context, c: WidgetContent): RemoteViews =
            WidgetHub.responsive(MEDIUM_AT, LARGE_AT) { size -> render(context, c, size) }

        private fun render(context: Context, c: WidgetContent, size: WidgetHub.Size): RemoteViews {
            val v = RemoteViews(context.packageName, R.layout.widget_list)
            WidgetHub.paint(v, R.id.list_root, R.id.list_tint, c.look)
            v.setOnClickPendingIntent(R.id.list_root, WidgetHub.openApp(context, WidgetHub.CODE_LIST_HEADER))

            if (c.tiles.isEmpty()) {
                // The empty state fills the card: Mochi asleep (or calm) with his glow, the headline and one clear line.
                v.setViewVisibility(R.id.list_header, View.GONE)
                v.setViewVisibility(R.id.list_rows, View.GONE)
                v.setViewVisibility(R.id.list_empty, View.VISIBLE)
                v.setImageViewBitmap(R.id.list_empty_face, MochiBitmap.of(c.mood, WidgetHub.px(context, 96), glow = true, tone = c.look))
                v.setContentDescription(R.id.list_empty_face, context.getString(R.string.widget_mochi_description, c.mood.key))
                v.setImageViewResource(R.id.list_empty_icon, if (c.connected) R.drawable.widget_dot else R.drawable.ic_widget_offline)
                v.setInt(R.id.list_empty_icon, "setColorFilter", c.look.argb)
                v.setTextViewText(R.id.list_empty_title, c.headline)
                v.setTextViewText(R.id.list_empty_line, c.emptyLine.orEmpty())
                return v
            }

            v.setViewVisibility(R.id.list_empty, View.GONE)
            v.setViewVisibility(R.id.list_header, View.VISIBLE)
            v.setViewVisibility(R.id.list_rows, View.VISIBLE)
            v.setInt(R.id.list_status, "setColorFilter", c.look.argb)
            v.setTextViewText(R.id.list_headline, c.headline)
            if (c.waiting > 0) {
                v.setTextViewText(R.id.list_badge, c.waiting.toString())
                v.setContentDescription(R.id.list_badge, context.getString(R.string.widget_badge_description, c.waiting))
                v.setViewVisibility(R.id.list_badge, View.VISIBLE)
            } else {
                v.setViewVisibility(R.id.list_badge, View.GONE)
            }
            val shown = when (size) {
                WidgetHub.Size.SMALL -> 2
                WidgetHub.Size.MEDIUM -> 3
                WidgetHub.Size.LARGE -> ROWS.size
            }
            val face = WidgetHub.px(context, 36)
            ROWS.forEachIndexed { i, r ->
                val tile = c.tiles.getOrNull(i)
                if (tile == null || i >= shown) {
                    v.setViewVisibility(r.row, View.GONE)
                    return@forEachIndexed
                }
                v.setViewVisibility(r.row, View.VISIBLE)
                v.setInt(r.stripe, "setColorFilter", tile.tone.argb)
                v.setImageViewBitmap(r.face, MochiBitmap.of(tile.state, face))
                v.setContentDescription(r.face, context.getString(R.string.widget_mochi_description, tile.stateWord.lowercase()))
                v.setTextViewText(r.name, tile.name)
                v.setTextViewText(r.state, tile.stateWord)
                v.setInt(r.dot, "setColorFilter", tile.tone.argb)
                v.setOnClickPendingIntent(r.row, WidgetHub.openSession(context, WidgetHub.CODE_LIST_ROW + i, tile.pillId))
            }
            return v
        }
    }
}
