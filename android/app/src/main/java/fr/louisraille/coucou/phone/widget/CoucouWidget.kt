package fr.louisraille.coucou.phone.widget

import android.content.Context
import android.content.Intent
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.action.clickable
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.updateAll
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import fr.louisraille.coucou.phone.Coucou
import fr.louisraille.coucou.phone.Prefs
import fr.louisraille.coucou.phone.R
import fr.louisraille.coucou.phone.Relay
import fr.louisraille.coucou.phone.urgencyOf
import org.json.JSONArray
import org.json.JSONObject

/**
 * The home-screen widget: one line per live session — the agent's coloured
 * dot, its name and what it is doing — or "All quiet" when nothing runs.
 * It never talks to the relay itself: the last state the app fetched is kept
 * in a snapshot (Prefs), and refresh() / a push calls push() to repaint.
 * A tap opens the app.
 */
class CoucouWidget : GlanceAppWidget() {

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val rows = snapshot(context)
        provideContent { Content(context, rows) }
    }

    @Composable
    private fun Content(ctx: Context, rows: List<Entry>) {
        Column(
            modifier = GlanceModifier
                .fillMaxSize()
                .background(Coucou.Hero)
                .padding(horizontal = 14.dp, vertical = 10.dp)
                .clickable(actionStartActivity(openIntent(ctx))),
        ) {
            Text(
                ctx.getString(R.string.app_name),
                style = TextStyle(
                    color = ColorProvider(Coucou.Ink),
                    fontSize = 15.sp,
                    fontWeight = FontWeight.Bold,
                ),
            )
            Spacer(GlanceModifier.height(6.dp))
            if (rows.isEmpty()) {
                Text(
                    ctx.getString(R.string.live_quiet),
                    style = TextStyle(color = ColorProvider(Coucou.Secondary), fontSize = 13.sp),
                )
            } else {
                rows.take(4).forEach { SessionLine(it) }
                if (rows.size > 4) {
                    Text(
                        ctx.getString(R.string.widget_more, rows.size - 4),
                        style = TextStyle(color = ColorProvider(Coucou.Tertiary), fontSize = 11.sp),
                    )
                }
            }
        }
    }

    @Composable
    private fun SessionLine(r: Entry) {
        Row(
            modifier = GlanceModifier.fillMaxWidth().padding(vertical = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = GlanceModifier.size(8.dp).cornerRadius(4.dp)
                    .background(ColorProvider(r.color)),
            ) {}
            Spacer(GlanceModifier.width(8.dp))
            Text(
                r.agent,
                style = TextStyle(
                    color = ColorProvider(Coucou.Ink),
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Medium,
                ),
                maxLines = 1,
            )
            Spacer(GlanceModifier.width(6.dp))
            Text(
                r.status,
                style = TextStyle(color = ColorProvider(Coucou.Secondary), fontSize = 12.sp),
                maxLines = 1,
            )
        }
    }

    private fun openIntent(ctx: Context): Intent =
        ctx.packageManager.getLaunchIntentForPackage(ctx.packageName) ?: Intent()

    /** One line on the widget: agent name, what it is doing, its colour. */
    private class Entry(val agent: String, val status: String, val state: String, val color: Color)

    private fun snapshot(ctx: Context): List<Entry> {
        val raw = Prefs.widgetSnapshot(ctx) ?: return emptyList()
        val arr = runCatching { JSONArray(raw) }.getOrNull() ?: return emptyList()
        return (0 until arr.length()).mapNotNull { i ->
            val o = arr.optJSONObject(i) ?: return@mapNotNull null
            Entry(
                agent = o.optString("agent"),
                status = o.optString("status"),
                state = o.optString("state"),
                color = Color(((o.optLong("color", -1).takeIf { it >= 0 }) ?: 0xFF7DB6FFL).toULong()),
            )
        }.sortedByDescending { urgencyOf(it.state) }
    }

    companion object {
        /**
         * The app just fetched fresh sessions: keep them for the widget and
         * repaint. Called from the poll loop and the push handler.
         */
        suspend fun push(ctx: Context, sessions: List<Relay.Session>) {
            val arr = JSONArray()
            sessions.forEach { s ->
                arr.put(
                    JSONObject()
                        .put("agent", s.agent)
                        .put("status", s.statusText.ifBlank { s.state })
                        .put("state", s.state)
                        .put("color", s.color.toLong() and 0xFFFFFFFFL),
                )
            }
            Prefs.setWidgetSnapshot(ctx, arr.toString())
            CoucouWidget().updateAll(ctx)
        }

        suspend fun clear(ctx: Context) {
            Prefs.setWidgetSnapshot(ctx, null)
            CoucouWidget().updateAll(ctx)
        }
    }
}

/** The launcher asks Android for this receiver; it only points at the widget. */
class CoucouWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = CoucouWidget()
}
