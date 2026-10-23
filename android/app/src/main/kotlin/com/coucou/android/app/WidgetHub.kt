package com.coucou.android.app

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.SizeF
import android.widget.RemoteViews
import com.coucou.android.MainActivity
import com.coucou.android.R
import com.coucou.android.core.LaunchScreen
import com.coucou.android.core.TodayMidnight
import com.coucou.android.core.UsageTone
import com.coucou.android.core.WidgetContent
import com.coucou.android.core.WidgetTone
import kotlin.math.roundToInt

/**
 * The one place that pushes the Widgets (Solo, List, Mochi Big, Status Pill, Waiting Alert, Usage Ring, Today, Mochi Mood and Team). The app calls [update] on every change of sessions, requests and
 * link (from AppModel.pushGlance); a push whose content is the same as the last one is dropped, so a change that does not
 * show on a widget costs nothing. There is no timer: a widget is drawn when something changes or when it is added, and the Today
 * widget once at local midnight (one inexact alarm, see [scheduleMidnight]).
 */
object WidgetHub {
    /** A Widget drawn once for all its copies ([views]), or once per copy when each has its own choice ([each], the Team widget). */
    private class Kind(
        val provider: Class<out AppWidgetProvider>,
        val each: ((Context, WidgetContent, Int) -> RemoteViews)? = null,
        val views: ((Context, WidgetContent) -> RemoteViews)? = null,
    )

    private val widgets = listOf(
        Kind(SoloWidget::class.java) { c, w -> SoloWidget.views(c, w) },
        Kind(ListWidget::class.java) { c, w -> ListWidget.views(c, w) },
        Kind(MochiBigWidget::class.java) { c, w -> MochiBigWidget.views(c, w) },
        Kind(StatusPillWidget::class.java) { c, w -> StatusPillWidget.views(c, w) },
        Kind(WaitingAlertWidget::class.java) { c, w -> WaitingAlertWidget.views(c, w) },
        Kind(UsageRingWidget::class.java) { c, w -> UsageRingWidget.views(c, w) },
        Kind(TodayWidget::class.java) { c, w -> TodayWidget.views(c, w) },
        Kind(MoodWidget::class.java) { c, w -> MoodWidget.views(c, w) },
        Kind(TeamWidget::class.java, each = { c, w, id -> TeamWidget.views(c, w, id) }),
    )

    private var last: WidgetContent? = null

    /** A sample pinned by the debug build's preview receiver (null in a release build, and in a debug one until asked). */
    private var pinned: WidgetContent? = null

    /** Pushes [content] to every Widget of the family on the home screen (none: nothing happens). */
    @Synchronized
    fun update(context: Context, content: WidgetContent) {
        if (pinned != null && content != pinned) return // a preview is on screen: real pushes wait
        if (content == last) return
        runCatching {
            val manager = AppWidgetManager.getInstance(context)
            var pushed = false
            val localized = AppLanguage.wrap(context) // before Android 13 the language chosen in the app
            for (kind in widgets) {
                val ids = manager.getAppWidgetIds(ComponentName(context, kind.provider))
                if (ids.isEmpty()) continue
                val shared = kind.views?.invoke(localized, content)
                for (id in ids) manager.updateAppWidget(id, shared ?: kind.each!!(localized, content, id))
                pushed = true
            }
            // With no widget on screen nothing is remembered, so the first one added is drawn.
            if (pushed) last = content
        }
    }

    /** Draws the widgets the system just created or resized, from what the app says now. */
    fun refresh(context: Context, manager: AppWidgetManager, ids: IntArray, views: (Context, WidgetContent) -> RemoteViews) {
        val rendered = views(AppLanguage.wrap(context), current(context))
        for (id in ids) runCatching { manager.updateAppWidget(id, rendered) }
    }

    /** The same for a Widget whose copies differ (the Team widget): each copy is drawn with its own id. */
    fun refreshEach(context: Context, manager: AppWidgetManager, ids: IntArray, views: (Context, WidgetContent, Int) -> RemoteViews) {
        val localized = AppLanguage.wrap(context)
        val content = current(context)
        for (id in ids) runCatching { manager.updateAppWidget(id, views(localized, content, id)) }
    }

    /** The three sizes a responsive Widget is drawn for (Android 12 and later picks one by the room it has). */
    enum class Size { SMALL, MEDIUM, LARGE }

    /**
     * One picture per size on Android 12 (API 31) and later; on Android 11 there is no size map, so the plain MEDIUM
     * picture is the only one. [mediumAt] and [largeAt] are where those sizes start, in dp (the system picks the largest
     * entry that fits, so SMALL starts at zero); [draw] builds the picture for a size from the same layout.
     */
    fun responsive(mediumAt: SizeF, largeAt: SizeF, draw: (Size) -> RemoteViews): RemoteViews =
        if (Build.VERSION.SDK_INT >= 31) {
            RemoteViews(mapOf(SizeF(0f, 0f) to draw(Size.SMALL), mediumAt to draw(Size.MEDIUM), largeAt to draw(Size.LARGE)))
        } else {
            draw(Size.MEDIUM)
        }

    /** dp to pixels on this screen, at least 1. */
    fun px(context: Context, dp: Int): Int = (dp * context.resources.displayMetrics.density).roundToInt().coerceAtLeast(1)

    /** The card (a 1dp border in the state's colour) and its gradient for a tone: the one place a Widget turns a state into colours. */
    fun paint(v: RemoteViews, root: Int, tint: Int, tone: WidgetTone) {
        v.setInt(root, "setBackgroundResource", cardOf(tone))
        v.setInt(tint, "setBackgroundResource", tintOf(tone))
    }

    /** The same for a plan-usage Widget: the usage palette (teal, yellow, red), never a state colour. */
    fun paintUsage(v: RemoteViews, root: Int, tint: Int, tone: UsageTone) {
        v.setInt(root, "setBackgroundResource", when (tone) {
            UsageTone.CALM -> R.drawable.widget_card_usage_calm
            UsageTone.CLOSE -> R.drawable.widget_card_usage_close
            UsageTone.LIMIT -> R.drawable.widget_card_usage_limit
        })
        v.setInt(tint, "setBackgroundResource", when (tone) {
            UsageTone.CALM -> R.drawable.widget_tint_usage_calm
            UsageTone.CLOSE -> R.drawable.widget_tint_usage_close
            UsageTone.LIMIT -> R.drawable.widget_tint_usage_limit
        })
    }

    private fun cardOf(tone: WidgetTone): Int = when (tone) {
        WidgetTone.MUTED -> R.drawable.widget_card_muted
        WidgetTone.IDLE -> R.drawable.widget_card_idle
        WidgetTone.WORKING -> R.drawable.widget_card_working
        WidgetTone.ATTENTION -> R.drawable.widget_card_attention
        WidgetTone.DONE -> R.drawable.widget_card_done
        WidgetTone.TROUBLE -> R.drawable.widget_card_trouble
    }

    private fun tintOf(tone: WidgetTone): Int = when (tone) {
        WidgetTone.MUTED -> R.drawable.widget_tint_muted
        WidgetTone.IDLE -> R.drawable.widget_tint_idle
        WidgetTone.WORKING -> R.drawable.widget_tint_working
        WidgetTone.ATTENTION -> R.drawable.widget_tint_attention
        WidgetTone.DONE -> R.drawable.widget_tint_done
        WidgetTone.TROUBLE -> R.drawable.widget_tint_trouble
    }

    /** What the Widgets show now: the pinned preview if there is one, else what the app says. */
    private fun current(context: Context): WidgetContent = pinned ?: (context.applicationContext as CoucouApp).model.widgetContent()

    /**
     * Shows [content] on every Widget and keeps it there (real pushes wait), or with null goes back to the real thing. Only the
     * debug build calls this, from its preview receiver; nothing in a release build does.
     */
    @Synchronized
    fun preview(context: Context, content: WidgetContent?) {
        pinned = content
        last = null
        update(context, current(context))
    }

    /** Draws every Widget again from what the app says now, even if nothing looks different (a new day, a new time zone). */
    @Synchronized
    fun refreshAll(context: Context) {
        last = null
        update(context, current(context))
    }

    /** The one alarm of the Widgets: the Today widget's redraw at the next local midnight (see [scheduleMidnight]). */
    const val ACTION_MIDNIGHT = "com.coucou.android.action.WIDGET_MIDNIGHT"

    private fun midnightIntent(context: Context): PendingIntent =
        PendingIntent.getBroadcast(
            context, CODE_MIDNIGHT, Intent(ACTION_MIDNIGHT).setClass(context, TodayWidget::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    /**
     * Asks the system to redraw the Today widget once, at the next local midnight, so the count starts again at 0 even if nothing else
     * redraws it (Android no longer delivers "the date changed" to manifest receivers). One inexact alarm that does not wake the phone
     * and needs no permission; it replaces itself each time, and is set again when the alarm fires and whenever the Widget is updated.
     */
    fun scheduleMidnight(context: Context) {
        runCatching {
            val alarms = context.getSystemService(AlarmManager::class.java) ?: return
            alarms.set(AlarmManager.RTC, TodayMidnight.nextAfter(System.currentTimeMillis()), midnightIntent(context))
        }
    }

    /** No Today widget is left on the home screen: the alarm is not needed. */
    fun cancelMidnight(context: Context) {
        runCatching { context.getSystemService(AlarmManager::class.java)?.cancel(midnightIntent(context)) }
    }

    /** Opens the app on Home. */
    fun openApp(context: Context, code: Int): PendingIntent {
        val open = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        return PendingIntent.getActivity(context, code, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    /**
     * Opens one session. It goes through LaunchActivity (our own, not exported) with an explicit component, never through
     * MainActivity's extras. Each call needs its own [code]: PendingIntents are told apart by code, not by extras.
     */
    fun openSession(context: Context, code: Int, pillId: String): PendingIntent {
        val open = Intent(context, LaunchActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .putExtra(LaunchActivity.EXTRA_SESSION, pillId)
        return PendingIntent.getActivity(context, code, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    /**
     * Opens one screen of the closed [LaunchScreen] list, for a button. Through LaunchActivity like [openSession]: explicit
     * component, immutable, one [code] of its own per button, and only the key of the screen travels. Nothing is changed.
     */
    fun openScreen(context: Context, code: Int, screen: LaunchScreen): PendingIntent {
        val open = Intent(context, LaunchActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .putExtra(LaunchActivity.EXTRA_SCREEN, screen.key)
        return PendingIntent.getActivity(context, code, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    /** Request codes: one range per widget, one code per row, so no two PendingIntents are the same. */
    const val CODE_SOLO = 0x5100
    const val CODE_LIST_HEADER = 0x5200
    const val CODE_LIST_ROW = 0x5300
    const val CODE_BIG = 0x5400
    const val CODE_PILL = 0x5500
    const val CODE_ALERT = 0x5600
    const val CODE_RING = 0x5700
    const val CODE_TODAY = 0x5800
    const val CODE_MOOD = 0x5900

    /** The buttons: one code each, from these bases (the Status Pill has 4, Mochi Big 6, the summary none). */
    const val CODE_PILL_BUTTON = 0x5A00
    const val CODE_BIG_BUTTON = 0x5B00
    const val CODE_GLANCE = 0x5C00

    /** Mochi Big's usage side: Settings when plan usage is off, the app otherwise. */
    const val CODE_BIG_USAGE_SETTINGS = 0x5D00
    const val CODE_BIG_USAGE_APP = 0x5E00
    const val CODE_MIDNIGHT = 0x5F00

    /** The Team widget: one code per agent (+ 0..3), one per agent that does not run (+ 4..7), and the card itself (+ 8). */
    const val CODE_TEAM = 0x6000
}
