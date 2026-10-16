package com.coucou.android.app

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.util.SizeF
import android.view.View
import android.widget.RemoteViews
import com.coucou.android.R
import com.coucou.android.core.LaunchScreen
import com.coucou.android.core.WidgetContent

/**
 * The Status Pill widget: one slim line. On the left a dot in the state's tone, the name of the most urgent agent and its state
 * word; on the right four round buttons (Home, Chat, Settings, Recent) that open that screen of the app. Narrower, the state
 * word goes first, then the name; the buttons never move and the text never runs under them. Drawn by [WidgetHub] when
 * something changes (updatePeriodMillis = 0). A tap on the text opens the top agent, or the app. It only opens things: no
 * button changes anything.
 */
class StatusPillWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) =
        WidgetHub.refresh(context, manager, ids) { c, w -> views(c, w) }

    companion object {
        // Width in dp: under 290 only the dot is left of the buttons, from 290 the name, from 360 the state word too.
        private val MEDIUM_AT = SizeF(290f, 0f)
        private val LARGE_AT = SizeF(360f, 0f)

        private class Button(val view: Int, val screen: LaunchScreen)

        private val BUTTONS = listOf(
            Button(R.id.pill_btn_home, LaunchScreen.HOME),
            Button(R.id.pill_btn_chat, LaunchScreen.CHAT),
            Button(R.id.pill_btn_settings, LaunchScreen.SETTINGS),
            Button(R.id.pill_btn_recent, LaunchScreen.RECENT),
        )

        fun views(context: Context, c: WidgetContent): RemoteViews =
            WidgetHub.responsive(MEDIUM_AT, LARGE_AT) { size -> render(context, c, size) }

        private fun render(context: Context, c: WidgetContent, size: WidgetHub.Size): RemoteViews {
            val v = RemoteViews(context.packageName, R.layout.widget_pill)
            WidgetHub.paint(v, R.id.pill_root, R.id.pill_tint, c.look)
            val top = c.top
            val name = top?.name ?: c.headline
            val state = top?.stateWord ?: c.emptyLine.orEmpty()
            v.setTextViewText(R.id.pill_name, name)
            v.setTextViewText(R.id.pill_state, state)
            v.setViewVisibility(R.id.pill_name, if (size == WidgetHub.Size.SMALL) View.GONE else View.VISIBLE)
            v.setViewVisibility(R.id.pill_state, if (size == WidgetHub.Size.LARGE) View.VISIBLE else View.GONE)
            v.setImageViewResource(R.id.pill_dot, if (top == null && !c.connected) R.drawable.ic_widget_offline else R.drawable.widget_dot)
            v.setInt(R.id.pill_dot, "setColorFilter", (top?.tone ?: c.look).argb)
            v.setContentDescription(R.id.pill_root, context.getString(R.string.widget_pill_cd, name, state))
            v.setOnClickPendingIntent(
                R.id.pill_root,
                if (top != null) WidgetHub.openSession(context, WidgetHub.CODE_PILL, top.pillId) else WidgetHub.openApp(context, WidgetHub.CODE_PILL),
            )
            BUTTONS.forEachIndexed { i, b ->
                v.setOnClickPendingIntent(b.view, WidgetHub.openScreen(context, WidgetHub.CODE_PILL_BUTTON + i, b.screen))
            }
            return v
        }
    }
}
