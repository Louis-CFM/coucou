package com.coucou.android.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import androidx.core.content.ContextCompat

/**
 * Tells the model when the screen turns on (or the phone is unlocked) and off. Registered only while a computer is paired; these are
 * system broadcasts that Android delivers to a running app, so nothing polls and nothing runs while the screen stays as it is.
 */
class ScreenWatch(context: Context, private val onChange: (on: Boolean) -> Unit) {
    private val app = context.applicationContext
    private var receiver: BroadcastReceiver? = null

    @Synchronized
    fun start() {
        if (receiver != null) return
        val r = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.action) {
                    Intent.ACTION_SCREEN_OFF -> onChange(false)
                    Intent.ACTION_SCREEN_ON, Intent.ACTION_USER_PRESENT -> onChange(true)
                }
            }
        }
        receiver = r
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_USER_PRESENT)
        }
        runCatching { ContextCompat.registerReceiver(app, r, filter, ContextCompat.RECEIVER_NOT_EXPORTED) }
    }

    @Synchronized
    fun stop() {
        receiver?.let { runCatching { app.unregisterReceiver(it) } }
        receiver = null
    }
}
