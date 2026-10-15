package com.coucou.android.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.coucou.android.core.WidgetData
import com.coucou.android.core.WidgetSample

/**
 * DEBUG BUILDS ONLY (this file lives in src/debug): look at every Widget in every state without a computer.
 *
 * Put the Widgets on the home screen, then, from a computer with the phone connected:
 *
 *   adb shell am broadcast -n com.coucou.android/.app.WidgetPreviewReceiver -a com.coucou.android.debug.WIDGET_STATE --es state disconnected
 *   adb shell am broadcast -n com.coucou.android/.app.WidgetPreviewReceiver -a com.coucou.android.debug.WIDGET_STATE --es state empty
 *   adb shell am broadcast -n com.coucou.android/.app.WidgetPreviewReceiver -a com.coucou.android.debug.WIDGET_STATE --es state working
 *   adb shell am broadcast -n com.coucou.android/.app.WidgetPreviewReceiver -a com.coucou.android.debug.WIDGET_STATE --es state waiting
 *   adb shell am broadcast -n com.coucou.android/.app.WidgetPreviewReceiver -a com.coucou.android.debug.WIDGET_STATE --es state done
 *   adb shell am broadcast -n com.coucou.android/.app.WidgetPreviewReceiver -a com.coucou.android.debug.WIDGET_STATE --es state live
 *
 * Optional `--ei usage <percent>` sets Claude's plan usage on Mochi Big and the Usage Ring (it resets in 2 h, shown as a clock time), to see the near-limit look
 * (red from 90, large rate, "Near limit", "resets at 14:30"). Without `--es state` it uses `working`; ignored for `disconnected` and `live`:
 *
 *   adb shell am broadcast -n com.coucou.android/.app.WidgetPreviewReceiver -a com.coucou.android.debug.WIDGET_STATE --es state working --ei usage 92
 *
 * `live` goes back to the real state. A chosen state stays on the Widgets (real changes wait) until `live` or until the app
 * process is killed. The states are made up by [WidgetSample]; nothing is read from, or sent to, a computer.
 */
class WidgetPreviewReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val usage = if (intent.hasExtra("usage")) intent.getIntExtra("usage", 0) else null
        val key = intent.getStringExtra("state")?.trim()?.lowercase() ?: if (usage != null) "working" else null
        if (key == "live") {
            WidgetHub.preview(context, null)
            return
        }
        val sample = WidgetSample.parse(key)
        if (sample == null) {
            Log.w("CoucouWidgets", "unknown state '$key': use disconnected, empty, working, waiting, done or live")
            return
        }
        WidgetHub.preview(context, WidgetData.sample(sample, System.currentTimeMillis(), usage))
    }
}
