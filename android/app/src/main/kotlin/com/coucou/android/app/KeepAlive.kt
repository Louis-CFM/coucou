package com.coucou.android.app

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.PowerManager
import android.os.SystemClock
import com.coucou.android.link.KeepAlivePolicy

/**
 * The heartbeat that works while the phone sleeps. Timers inside the app stop with the CPU, so a ping every 20 seconds cannot run in
 * Doze; an alarm can (`setAndAllowWhileIdle`: no special permission; Android runs it at most about every nine minutes in Doze and
 * may delay it to a maintenance window). Each time it fires the link is asked for a pong (reconnect if none) and the next alarm is set.
 */
object KeepAliveAlarm {
    private const val ACTION = "com.coucou.android.KEEP_ALIVE"

    private fun pending(context: Context): PendingIntent =
        PendingIntent.getBroadcast(
            context, 1, Intent(context, KeepAliveReceiver::class.java).setAction(ACTION),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

    fun arm(context: Context) {
        val app = context.applicationContext
        val am = app.getSystemService(AlarmManager::class.java) ?: return
        runCatching {
            am.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, SystemClock.elapsedRealtime() + KeepAlivePolicy.INTERVAL_MS, pending(app))
        }
    }

    fun cancel(context: Context) {
        val app = context.applicationContext
        runCatching { app.getSystemService(AlarmManager::class.java)?.cancel(pending(app)) }
    }
}

/** Not exported: only our own alarm can start it. */
class KeepAliveReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        // The phone may be going back to sleep the moment this returns, and the question to the computer and its answer need the CPU
        // for a few seconds. A wake lock with a timeout releases itself; it is never held longer than that, and never held between checks.
        runCatching {
            context.getSystemService(PowerManager::class.java)
                ?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "coucou:keepalive")
                ?.apply { setReferenceCounted(false); acquire(KeepAlivePolicy.WAKE_LOCK_MS) }
        }
        (context.applicationContext as CoucouApp).model.keepAliveTick()
    }
}
