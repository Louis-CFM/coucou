package com.coucou.android.app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.util.SizeF
import android.view.View
import android.widget.RemoteViews
import com.coucou.android.R
import com.coucou.android.core.LaunchScreen
import com.coucou.android.core.UsageRing
import com.coucou.android.core.UsageSide
import com.coucou.android.core.WidgetContent
import com.coucou.android.core.WidgetTone

/**
 * The Mochi Big widget (4x4). The top is in two sides. On the left, Mochi with his glow and his badge, then the agent's name and
 * state word, so the state reads without a sentence. On the right, the plan usage: up to two rows (Claude and Codex), each with a thin
 * bar that is teal, yellow from 75% and red from 90%. Under the red line the percentage is small and normal; from 90% it is big and
 * bold with "Near limit" and, when known, when it resets. When plan usage is off or the computer is not there, one calm message.
 * Under them, rounded buttons that only open a screen of the app (Home, Chat, Settings, Recent, the top agent, Pair again): none
 * when the card is small, one row of four from the medium size, two rows of three when large; tinted orange while something waits.
 * Drawn by [WidgetHub] when something changes (updatePeriodMillis = 0). A tap on the card opens the top agent, or the app.
 * Nothing here changes anything.
 */
class MochiBigWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) =
        WidgetHub.refresh(context, manager, ids) { c, w -> views(c, w) }

    companion object {
        // Height in dp: under 290 no buttons, from 290 one row of four, from 400 two rows of three.
        private val MEDIUM_AT = SizeF(0f, 290f)
        private val LARGE_AT = SizeF(0f, 400f)

        /** The six buttons, in order; null is the top agent (a session, not a screen). */
        private val BUTTONS: List<LaunchScreen?> = listOf(
            LaunchScreen.HOME, LaunchScreen.CHAT, LaunchScreen.SETTINGS, LaunchScreen.RECENT, null, LaunchScreen.PAIR,
        )

        // The same buttons in the two arrangements: the first four in the single row, all six in the two rows of three.
        private val ROW_TILES = listOf(R.id.big_m_home, R.id.big_m_chat, R.id.big_m_settings, R.id.big_m_recent)
        private val GRID_TILES = listOf(R.id.big_l_home, R.id.big_l_chat, R.id.big_l_settings, R.id.big_l_recent, R.id.big_l_session, R.id.big_l_pair)

        fun views(context: Context, c: WidgetContent): RemoteViews =
            WidgetHub.responsive(MEDIUM_AT, LARGE_AT) { size -> render(context, c, size) }

        private fun render(context: Context, c: WidgetContent, size: WidgetHub.Size): RemoteViews {
            val v = RemoteViews(context.packageName, R.layout.widget_big)
            WidgetHub.paint(v, R.id.big_root, R.id.big_tint, c.look)
            val top = c.top
            val large = size == WidgetHub.Size.LARGE
            val small = size == WidgetHub.Size.SMALL

            // Left: Mochi with his glow, then the agent and its state word.
            v.setImageViewBitmap(R.id.big_mochi, MochiBitmap.of(c.mood, WidgetHub.px(context, if (large) 170 else if (small) 120 else 140), glow = true, tone = c.look))
            v.setContentDescription(R.id.big_mochi, context.getString(R.string.widget_mochi_description, (top?.stateWord ?: c.headline).lowercase()))
            // Not connected: the "not connected" icon instead of the dot, and the headline instead of an agent.
            v.setViewVisibility(R.id.big_offline, if (c.connected) View.GONE else View.VISIBLE)
            if (top != null) {
                v.setViewVisibility(R.id.big_row, View.VISIBLE)
                v.setViewVisibility(R.id.big_dot, View.VISIBLE)
                v.setInt(R.id.big_dot, "setColorFilter", top.tone.argb)
                v.setTextViewText(R.id.big_name, top.name)
                v.setTextViewText(R.id.big_state, top.stateWord)
            } else {
                v.setViewVisibility(R.id.big_row, if (c.connected) View.GONE else View.VISIBLE)
                v.setViewVisibility(R.id.big_dot, View.GONE)
                v.setTextViewText(R.id.big_name, c.headline)
                v.setTextViewText(R.id.big_state, c.emptyLine.orEmpty())
            }
            v.setViewVisibility(R.id.big_state, View.VISIBLE)

            bindUsage(v, context, c, small)

            // Buttons: none when small, one row of four by default, two rows of three when large. They only open things.
            v.setViewVisibility(R.id.big_buttons, if (small) View.GONE else View.VISIBLE)
            v.setViewVisibility(R.id.big_buttons_m, if (large) View.GONE else View.VISIBLE)
            v.setViewVisibility(R.id.big_buttons_l, if (large) View.VISIBLE else View.GONE)
            val tile = if (c.look == WidgetTone.ATTENTION) R.drawable.widget_tile_bg_attention else R.drawable.widget_tile_bg
            for (tiles in listOf(ROW_TILES, GRID_TILES)) {
                tiles.forEachIndexed { i, id ->
                    v.setInt(id, "setBackgroundResource", tile)
                    v.setOnClickPendingIntent(id, buttonIntent(context, c, i))
                }
            }

            if (c.waiting > 0) {
                v.setTextViewText(R.id.big_badge, c.waiting.toString())
                v.setContentDescription(R.id.big_badge, context.getString(R.string.widget_badge_description, c.waiting))
                v.setViewVisibility(R.id.big_badge, View.VISIBLE)
            } else {
                v.setViewVisibility(R.id.big_badge, View.GONE)
            }
            v.setOnClickPendingIntent(
                R.id.big_root,
                if (top != null) WidgetHub.openSession(context, WidgetHub.CODE_BIG, top.pillId) else WidgetHub.openApp(context, WidgetHub.CODE_BIG),
            )
            return v
        }

        /** What button [i] opens. Both arrangements use the same code for the same button, so no two buttons share one. */
        private fun buttonIntent(context: Context, c: WidgetContent, i: Int): PendingIntent {
            val screen = BUTTONS[i]
            val top = c.top
            return when {
                screen != null -> WidgetHub.openScreen(context, WidgetHub.CODE_BIG_BUTTON + i, screen)
                top != null -> WidgetHub.openSession(context, WidgetHub.CODE_BIG_BUTTON + i, top.pillId)
                else -> WidgetHub.openScreen(context, WidgetHub.CODE_BIG_BUTTON + i, LaunchScreen.HOME) // no agent yet: the app
            }
        }

        /**
         * The right side, never empty: up to two plan-usage rows (a big percentage with a thin bar; only the first when small), or a
         * calm message when plan usage is off (a tap opens Settings) or the computer is not there (a tap opens the app).
         */
        private fun bindUsage(v: RemoteViews, context: Context, c: WidgetContent, small: Boolean) {
            val rows = c.usageRows
            when (c.usageSide) {
                UsageSide.ROWS -> {
                    v.setViewVisibility(R.id.big_off, View.GONE)
                    bindRow(v, context, rows[0], BigRow(R.id.big_usage_a, R.id.big_usage_a_label, R.id.big_usage_a_pct, R.id.big_usage_a_pct_big, R.id.big_usage_a_note, R.id.big_usage_a_bar))
                    val second = rows.getOrNull(1)?.takeIf { !small }
                    if (second != null) bindRow(v, context, second, BigRow(R.id.big_usage_b, R.id.big_usage_b_label, R.id.big_usage_b_pct, R.id.big_usage_b_pct_big, R.id.big_usage_b_note, R.id.big_usage_b_bar))
                    else v.setViewVisibility(R.id.big_usage_b, View.GONE)
                    v.setOnClickPendingIntent(R.id.big_right, WidgetHub.openApp(context, WidgetHub.CODE_BIG_USAGE_APP))
                }
                UsageSide.OFF, UsageSide.NOT_CONNECTED -> {
                    v.setViewVisibility(R.id.big_usage_a, View.GONE)
                    v.setViewVisibility(R.id.big_usage_b, View.GONE)
                    v.setViewVisibility(R.id.big_off, View.VISIBLE)
                    if (c.usageSide == UsageSide.NOT_CONNECTED) {
                        v.setTextViewText(R.id.big_off_title, context.getString(R.string.widget_big_not_connected))
                        v.setTextViewText(R.id.big_off_line, c.emptyLine.orEmpty())
                        v.setOnClickPendingIntent(R.id.big_right, WidgetHub.openApp(context, WidgetHub.CODE_BIG_USAGE_APP))
                    } else {
                        v.setTextViewText(R.id.big_off_title, context.getString(R.string.widget_big_usage_off))
                        v.setTextViewText(R.id.big_off_line, context.getString(R.string.widget_big_usage_off_line))
                        v.setOnClickPendingIntent(R.id.big_right, WidgetHub.openScreen(context, WidgetHub.CODE_BIG_USAGE_SETTINGS, LaunchScreen.SETTINGS))
                    }
                }
            }
        }

        private class BigRow(val group: Int, val label: Int, val pct: Int, val pctBig: Int, val note: Int, val bar: Int)

        /**
         * One plan-usage row. Under the red line the percentage is small and normal, with no warning. From the red line it is big and
         * bold, with "Near limit" (and when it resets) under it. The bar is teal, yellow from 75% and red from 90%.
         */
        private fun bindRow(v: RemoteViews, context: Context, row: UsageRing, r: BigRow) {
            v.setViewVisibility(r.group, View.VISIBLE)
            v.setTextViewText(r.label, row.label)
            val near = row.nearLimit
            v.setViewVisibility(r.pct, if (near) View.GONE else View.VISIBLE)
            v.setViewVisibility(r.pctBig, if (near) View.VISIBLE else View.GONE)
            v.setTextViewText(if (near) r.pctBig else r.pct, "${row.shown}%")
            v.setViewVisibility(r.note, if (row.note != null) View.VISIBLE else View.GONE)
            v.setTextViewText(r.note, row.note.orEmpty())
            v.setImageViewBitmap(r.bar, BarBitmap.of(row, WidgetHub.px(context, 180), WidgetHub.px(context, 6)))
            v.setContentDescription(r.group, context.getString(R.string.widget_ring_cd, row.plan, row.shown))
        }
    }
}
