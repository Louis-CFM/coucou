package com.coucou.android.mochi

import com.coucou.android.mochi.outfit.Outfit
import kotlin.random.Random
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** setOutfit and the soft-part physics, as in windows/src/mochi/engine.ts. */
class OutfitEngineTest {
    private class Clock { var ms = 10_000.0 }

    private fun engine(clock: Clock) = MochiEngine({ clock.ms }, Random(1), SoundSink { })

    private fun MochiEngine.run(clock: Clock, ms: Int) {
        repeat(ms / 16) { clock.ms += 16; update(0.016) }
    }

    @Test fun mochiStartsUndressed() {
        val e = engine(Clock())
        assertEquals(Outfit.NONE, e.outfit)
        assertEquals(0.0, e.outfitPresence, 0.0)
        assertFalse(e.rigidRoll)
    }

    @Test fun anOutfitDropsInOver350msAndThenMochiSquashes() {
        val clock = Clock()
        val e = engine(clock)
        e.setOutfit(Outfit.CROWN)
        assertEquals("the outfit is chosen at once", Outfit.CROWN, e.outfit)
        assertEquals(0.0, e.outfitPresence, 0.0)
        e.run(clock, 160)
        assertTrue(e.outfitPresence in 0.05..0.95)
        e.run(clock, 240)
        assertEquals(1.0, e.outfitPresence, 1e-9)
        assertTrue("squash runs when it has landed", e.sy != 1.0 || e.sx != 1.0)
    }

    @Test fun anOutfitLeavesOver180msAndThenIsGone() {
        val clock = Clock()
        val e = engine(clock)
        e.setOutfit(Outfit.BEANIE, animated = false)
        assertEquals(1.0, e.outfitPresence, 0.0)
        e.setOutfit(Outfit.NONE)
        e.run(clock, 96)
        assertTrue(e.outfitPresence in 0.01..0.99)
        assertEquals("still drawn while it leaves", Outfit.BEANIE, e.outfit)
        e.run(clock, 160)
        assertEquals(Outfit.NONE, e.outfit)
        assertEquals(0.0, e.outfitPresence, 1e-9)
    }

    @Test fun changingOutfitTakesTheOldOneOffFirst() {
        val clock = Clock()
        val e = engine(clock)
        e.setOutfit(Outfit.BEANIE, animated = false)
        e.setOutfit(Outfit.BOW)
        assertEquals("the old one is still shown", Outfit.BEANIE, e.outfit)
        e.run(clock, 208)
        assertEquals(Outfit.BOW, e.outfit)
        e.run(clock, 400)
        assertEquals(1.0, e.outfitPresence, 1e-9)
    }

    @Test fun theSameOutfitTwiceChangesNothing() {
        val clock = Clock()
        val e = engine(clock)
        e.setOutfit(Outfit.SCARF, animated = false)
        e.setOutfit(Outfit.SCARF)
        assertEquals(1.0, e.outfitPresence, 0.0)
    }

    @Test fun aVisibleOutfitMakesTheBodyRollAsOnePieceButAMiniNeverWearsOne() {
        val clock = Clock()
        val e = engine(clock)
        e.setOutfit(Outfit.CROWN, animated = false)
        assertTrue(e.rigidRoll)
        val mini = engine(clock).also { it.isMini = true }
        mini.setOutfit(Outfit.CROWN, animated = false)
        assertFalse(mini.rigidRoll)
    }

    @Test fun aSlapSetsTheSoftPartsSwingingAndTheyCalmDown() {
        val clock = Clock()
        val e = engine(clock)
        e.setOutfit(Outfit.SANTA_HAT, animated = false)
        e.slap()
        e.run(clock, 80)
        assertTrue(e.busy)
        assertTrue(Math.abs(e.physDy) > 0.001 || Math.abs(e.physDx) > 0.001)
        e.run(clock, 6000)
        assertTrue(Math.abs(e.physDx) < 0.05)
    }
}
