package com.coucou.android

import com.coucou.android.core.Ease
import com.coucou.android.mochi.BotEmote
import com.coucou.android.mochi.BotState
import com.coucou.android.mochi.EyeShape
import com.coucou.android.mochi.MochiEngine
import com.coucou.android.mochi.MochiGeometry
import com.coucou.android.mochi.ParticleType
import com.coucou.android.mochi.Prop
import com.coucou.android.mochi.SoundSink
import com.coucou.android.mochi.TweenKey
import kotlin.math.abs
import kotlin.math.pow
import kotlin.random.Random
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MochiEngineTest {
    private class Clock { var ms = 10_000.0 }

    private fun engine(clock: Clock, sounds: MutableList<String> = mutableListOf()) =
        MochiEngine({ clock.ms }, Random(1), SoundSink { sounds.add(it) })

    /** Advances the clock in 16 ms frames, as a 60 fps host would. */
    private fun MochiEngine.run(clock: Clock, ms: Int) {
        repeat(ms / 16) { clock.ms += 16; update(0.016) }
    }

    @Test fun easingsHitEndpoints() {
        for (f in listOf(Ease.out, Ease.inOut, Ease.back, Ease.lin, Ease.easeIn)) {
            assertEquals(0.0, f(0.0), 1e-9)
            assertEquals(1.0, f(1.0), 1e-9)
        }
        assertEquals(0.5, Ease.inOut(0.5), 1e-9)
        assertTrue("back overshoots", Ease.back(0.8) > 1.0)
    }

    @Test fun bodyIsASuperellipseOfExponent2_7() {
        val rx = 1.14
        val ry = 0.88
        for (p in MochiGeometry.bodyPoints(rx, ry, 1.0, 0.0)) {
            val v = abs(p.x / rx).pow(2.7) + abs(p.y / ry).pow(2.7)
            assertEquals(1.0, v, 1e-6)
        }
        val first = MochiGeometry.bodyPoints(rx, ry, 1.0, 0.0).first()
        assertEquals(rx, first.x, 1e-9)
        assertEquals(0.0, first.y, 1e-9)
    }

    @Test fun fullMorphGivesTheMailboxOutline() {
        val pts = MochiGeometry.bodyPoints(1.14, 0.88, 1.0, 1.0)
        assertEquals(MochiGeometry.BODY_SEGMENTS + 1, pts.size)
        // The box is 1.0 wide and 0.94 tall (tw, th in engine.ts).
        assertTrue(pts.all { abs(it.x) <= 1.0 + 1e-6 && abs(it.y) <= 0.94 + 1e-6 })
        assertEquals(1.0, pts.first().x, 1e-9)
    }

    @Test fun tweenRunsKeysInOrderAndLocksTheProperty() {
        val clock = Clock()
        val e = engine(clock)
        var done = false
        e.anim(Prop.OX, listOf(TweenKey(1.0, 100.0, Ease.lin), TweenKey(0.0, 100.0, Ease.lin))) { done = true }
        clock.ms += 50; e.update(0.05)
        assertEquals(0.5, e.ox, 1e-9)
        clock.ms += 50; e.update(0.05)
        assertEquals(1.0, e.ox, 1e-9)
        clock.ms += 100; e.update(0.1)
        assertEquals(0.0, e.ox, 1e-9)
        assertTrue(done)
    }

    @Test fun settingAStateCopiesItsConfig() {
        val clock = Clock()
        val e = engine(clock)
        e.setState(BotState.APPROVAL)
        assertEquals(EyeShape.WIDE, e.cfg.eye)
        assertEquals(0.78, e.tint, 1e-9)
        e.run(clock, 600)
        assertEquals(1.0, e.badgeS, 0.01)
        assertEquals(com.coucou.android.mochi.BadgeKind.BANG, e.badge?.kind)
    }

    @Test fun colourEasesTowardsTheStateColour() {
        val clock = Clock()
        val e = engine(clock)
        e.setState(BotState.ERROR)
        e.run(clock, 3000)
        assertEquals(e.colT.r, e.col.r, 0.01)
        assertEquals(e.colT.g, e.col.g, 0.01)
    }

    @Test fun loveEmotePutsHeartsInTheEyesAndEmitsHearts() {
        val clock = Clock()
        val e = engine(clock)
        e.triggerEmote(BotEmote.LOVE, 1.8)
        assertEquals(EyeShape.HEART, e.eyeOverride)
        assertEquals(4, e.particles.count { it.type == ParticleType.HEART })
        e.run(clock, 2000)
        assertNull("override expires", e.eyeOverride)
    }

    @Test fun permanentEmoteSticksUntilCleared() {
        val clock = Clock()
        val e = engine(clock)
        e.setPermanentEmote(BotEmote.HAPPY)
        e.run(clock, 5000)
        assertEquals(EyeShape.HAPPY, e.eyeOverride)
        e.setPermanentEmote(null)
        e.run(clock, 100)
        assertNull(e.eyeOverride)
    }

    @Test fun threeSlapsWithin1_7sMakeMochiDizzy() {
        val clock = Clock()
        val sounds = mutableListOf<String>()
        val e = engine(clock, sounds)
        var dizzy = false
        e.onDizzy = { dizzy = true }
        e.slap(); clock.ms += 300; e.update(0.3)
        e.slap(); clock.ms += 300; e.update(0.3)
        assertFalse(dizzy)
        e.slap()
        assertTrue(dizzy)
        assertTrue(sounds.contains("slap"))
    }

    @Test fun slapsSpacedOutDoNotAccumulate() {
        val clock = Clock()
        val e = engine(clock)
        var dizzy = false
        e.onDizzy = { dizzy = true }
        repeat(3) { e.slap(); clock.ms += 2000; e.update(2.0) }
        assertFalse(dizzy)
    }

    @Test fun greetWavesThenLowersItsHands() {
        val clock = Clock()
        val sounds = mutableListOf<String>()
        val e = engine(clock, sounds)
        e.greet()
        e.run(clock, 800)
        assertTrue(e.hands > 0.9)
        assertTrue(sounds.contains("greet"))
        e.run(clock, 1600)
        assertEquals(0.0, e.hands, 0.01)
    }

    @Test fun interruptedGreetDoesNotRaiseHandsLater() {
        val clock = Clock()
        val e = engine(clock)
        e.greet()
        e.interruptGreet()
        e.run(clock, 2500)
        assertEquals(0.0, e.hands, 0.01)
    }

    @Test fun sleepingBreathesAndEmitsZs() {
        val clock = Clock()
        val e = engine(clock)
        e.setState(BotState.SLEEPING)
        e.run(clock, 3000)
        assertTrue(e.particles.any { it.type == ParticleType.Z })
        assertTrue(e.busy)
    }

    @Test fun idleSettlesAndStopsBeingBusy() {
        val clock = Clock()
        val e = engine(clock)
        e.run(clock, 10_000)
        assertFalse("idle Mochi should let the frame loop sleep", e.busy)
    }

    @Test fun gulpOpensThenClosesTheSlot() {
        val clock = Clock()
        val e = engine(clock)
        e.animateMorph(1.0, 10.0)
        e.gulp()
        e.run(clock, 300)
        assertTrue(e.slotH > 0.1)
        e.run(clock, 2500)
        assertEquals(0.0, e.slotH, 0.01)
        assertFalse(e.isChewing)
    }
}
