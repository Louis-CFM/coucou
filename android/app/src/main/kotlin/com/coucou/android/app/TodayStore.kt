package com.coucou.android.app

import android.content.Context
import com.coucou.android.core.TodayStorage

/** The day's count of finished tasks, in this app's private preferences. It stays on the phone: nothing sends it anywhere. */
class TodayStore(context: Context) : TodayStorage {
    private val prefs = context.getSharedPreferences("widget_today", Context.MODE_PRIVATE)

    override fun load(): Pair<String, Int>? {
        val day = prefs.getString(DAY, null) ?: return null
        return day to prefs.getInt(COUNT, 0)
    }

    override fun save(day: String, count: Int) {
        prefs.edit().putString(DAY, day).putInt(COUNT, count).apply()
    }

    private companion object {
        const val DAY = "day"
        const val COUNT = "count"
    }
}
