package com.coucou.android

import com.coucou.android.core.KeyValueStore
import com.coucou.android.core.MotionChoice
import com.coucou.android.core.MotionPolicy
import com.coucou.android.core.UserSettings
import com.coucou.android.mochi.BotState
import com.coucou.android.mochi.MochiEngine
import com.coucou.android.mochi.SoundSink
import java.io.File
import kotlin.random.Random
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReduceMotionTest {
    private class Clock { var ms = 10_000.0 }
    private fun engine(clock: Clock, state: BotState) =
        MochiEngine({ clock.ms }, Random(1), SoundSink { }).apply { setState(state, force = true) }
    private fun MochiEngine.run(clock: Clock, ms: Int) { repeat(ms / 16) { clock.ms += 16; update(0.016) } }

    @Test fun followsTheSystemUnlessTheUserChoseOtherwise() {
        assertTrue(MotionPolicy.reduced(MotionChoice.SYSTEM, 0f))
        assertFalse(MotionPolicy.reduced(MotionChoice.SYSTEM, 1f))
        assertFalse(MotionPolicy.reduced(MotionChoice.SYSTEM, 0.5f))
        assertTrue(MotionPolicy.reduced(MotionChoice.REDUCE, 1f))
        assertFalse(MotionPolicy.reduced(MotionChoice.FULL, 0f))
    }

    @Test fun theDefaultFollowsTheSystemAndIsSaved() {
        assertEquals(MotionChoice.SYSTEM, UserSettings().motion)
        assertEquals(MotionChoice.SYSTEM, MotionChoice.parse(null))
        assertEquals(MotionChoice.SYSTEM, MotionChoice.parse("fast"))
        for (c in MotionChoice.values()) assertEquals(c, MotionChoice.parse(c.key))
        val m = HashMap<String, Any>()
        val store = object : KeyValueStore {
            override fun getBoolean(key: String, default: Boolean) = m[key] as? Boolean ?: default
            override fun getInt(key: String, default: Int) = m[key] as? Int ?: default
            override fun getFloat(key: String, default: Float) = m[key] as? Float ?: default
            override fun getString(key: String, default: String) = m[key] as? String ?: default
            override fun put(key: String, value: Any) { m[key] = value }
        }
        UserSettings.save(store, UserSettings(motion = MotionChoice.REDUCE))
        assertEquals(MotionChoice.REDUCE, UserSettings.load(store).motion)
    }

    @Test fun anIdleBouncingMochiStopsWhenMotionIsReduced() {
        val clock = Clock()
        val moving = engine(clock, BotState.APPROVAL) // bounces for as long as he waits
        moving.run(clock, 3_000)
        assertTrue("without reduce motion he keeps moving", moving.busy)

        val still = engine(clock, BotState.APPROVAL).apply { reduceMotion = true }
        still.run(clock, 3_000)
        assertFalse("with it, nothing idles once the state has played", still.busy)
        assertEquals(0.0, still.oy, 1e-3)
    }

    @Test fun aSleepingMochiEmitsNoFloatingZsWhenMotionIsReduced() {
        val clock = Clock()
        val still = engine(clock, BotState.SLEEPING).apply { reduceMotion = true }
        still.run(clock, 6_000)
        assertTrue(still.particles.isEmpty())
        assertFalse(still.busy)
        val moving = engine(clock, BotState.SLEEPING)
        moving.run(clock, 6_000)
        assertTrue("normally the Zs float up", moving.particles.isNotEmpty() || moving.busy)
    }

    @Test fun aChangeOfStateStillPlaysThenMochiIsStill() {
        val clock = Clock()
        val e = engine(clock, BotState.IDLE).apply { reduceMotion = true }
        e.run(clock, 1_000)
        e.setState(BotState.FINISHED)
        e.run(clock, 4_000)
        assertFalse(e.busy)
    }

    @Test fun settingsOffersTheChoice() {
        val ui = File("src/main/kotlin/com/coucou/android/ui/SettingsScreens.kt").readText()
        assertTrue(ui.contains("MotionChoice.REDUCE") && ui.contains("R.string.settings_motion"))
        // The island and the Mochi view both ask the one policy.
        assertTrue(File("src/main/kotlin/com/coucou/android/ui/IslandOverlay.kt").readText().contains("MotionPolicy.reduced"))
        assertTrue(File("src/main/kotlin/com/coucou/android/ui/DesignSystem.kt").readText().contains("MotionPolicy.reduced"))
        assertTrue(File("src/main/kotlin/com/coucou/android/mochi/MochiView.kt").readText().contains("engine.reduceMotion"))
    }
}
