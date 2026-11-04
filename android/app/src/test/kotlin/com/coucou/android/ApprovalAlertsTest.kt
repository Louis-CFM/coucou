package com.coucou.android

import com.coucou.android.core.ApprovalChannels
import com.coucou.android.core.KeyValueStore
import com.coucou.android.core.UserSettings
import com.coucou.android.core.VibrationChoice
import java.io.File
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ApprovalAlertsTest {
    private class MapStore : KeyValueStore {
        val m = HashMap<String, Any>()
        override fun getBoolean(key: String, default: Boolean) = m[key] as? Boolean ?: default
        override fun getInt(key: String, default: Int) = m[key] as? Int ?: default
        override fun getFloat(key: String, default: Float) = m[key] as? Float ?: default
        override fun getString(key: String, default: String) = m[key] as? String ?: default
        override fun put(key: String, value: Any) { m[key] = value }
    }

    @Test fun theDefaultsAreTodaysBehaviour() {
        val d = UserSettings()
        assertFalse("the screen wakes as before", d.keepScreenOff)
        assertEquals(VibrationChoice.STANDARD, d.vibration)
        assertArrayEquals("the pattern is the one the app always had", longArrayOf(0, 500, 150, 500), VibrationChoice.STANDARD.pattern)
        assertEquals(d, UserSettings.load(MapStore()))
    }

    @Test fun theChoicesAreSavedAndRead() {
        val store = MapStore()
        UserSettings.save(store, UserSettings(keepScreenOff = true, vibration = VibrationChoice.SHORT))
        val back = UserSettings.load(store)
        assertTrue(back.keepScreenOff)
        assertEquals(VibrationChoice.SHORT, back.vibration)
        assertArrayEquals(longArrayOf(0, 200), back.vibration.pattern)
        UserSettings.save(store, back.copy(vibration = VibrationChoice.OFF))
        assertNull(UserSettings.load(store).vibration.pattern)
    }

    @Test fun anUnknownVibrationKeyIsTheStandardOne() {
        assertEquals(VibrationChoice.STANDARD, VibrationChoice.parse(null))
        assertEquals(VibrationChoice.STANDARD, VibrationChoice.parse("strong"))
        for (v in VibrationChoice.values()) assertEquals(v, VibrationChoice.parse(v.key))
    }

    @Test fun eachChoiceHasItsOwnChannelAndTheOldOnesGoAway() {
        // A channel's vibration cannot change after it exists: a new id per choice, and only the chosen one is kept.
        assertEquals("the id the app has always used", "approvals_v3", ApprovalChannels.id(VibrationChoice.STANDARD))
        val ids = VibrationChoice.values().map { ApprovalChannels.id(it) }
        assertEquals(ids.size, ids.toSet().size)
        for (v in VibrationChoice.values()) {
            val gone = ApprovalChannels.othersThan(v)
            assertFalse(ApprovalChannels.id(v) in gone)
            assertEquals(VibrationChoice.values().size - 1, gone.size)
        }
    }

    @Test fun aRequestIsNeverMutedByTheseChoices() {
        val src = File("src/main/kotlin/com/coucou/android/app/Notifications.kt").readText()
        // The channel is always high importance with Mochi's sound; the choices only touch vibration and the wake.
        val block = src.substringAfter("fun applyApprovalSettings").substringBefore("private fun open(")
        assertTrue(block.contains("IMPORTANCE_HIGH"))
        assertTrue(block.contains("R.raw.approval"))
        assertFalse(block.contains("IMPORTANCE_LOW") || block.contains("IMPORTANCE_NONE") || block.contains("IMPORTANCE_MIN"))
        assertTrue(src.contains("!keepScreenOff) wakeScreen()"))
        // The notification is posted whatever the choices are.
        assertTrue(src.contains("runCatching { nm.notify(id, n) }"))
    }

    @Test fun settingsShowBothChoices() {
        val ui = File("src/main/kotlin/com/coucou/android/ui/SettingsScreens.kt").readText()
        assertTrue(ui.contains("R.string.settings_no_wake") && ui.contains("R.string.settings_vibration"))
        assertTrue(ui.contains("VibrationChoice.SHORT") && ui.contains("VibrationChoice.OFF"))
    }
}
