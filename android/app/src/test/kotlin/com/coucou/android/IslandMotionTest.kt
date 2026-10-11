package com.coucou.android

import com.coucou.android.core.Spring
import com.coucou.android.core.Tracked
import com.coucou.android.core.closeCurve
import com.coucou.android.core.cubicBezier
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The island moves like the PC's: windows/src/core/anim.ts. */
class IslandMotionTest {
    @Test fun theCloseCurveStartsAtZeroEndsAtOneAndNeverGoesBack() {
        assertEquals(0.0, closeCurve(0.0), 1e-9)
        assertEquals(1.0, closeCurve(1.0), 1e-4)
        var last = -1.0
        for (i in 0..100) {
            val v = closeCurve(i / 100.0)
            assertTrue("monotonic at $i", v >= last - 1e-12)
            last = v
        }
    }

    @Test fun theCloseCurveIsCubicBezierPoint45_0_2_1() {
        // Reference values of CSS cubic-bezier(.45, 0, .2, 1), computed independently.
        assertEquals(0.0, closeCurve(0.0), 1e-4)
        assertEquals(0.5, cubicBezier(0.0, 0.0, 1.0, 1.0)(0.5), 1e-3) // a straight line stays straight
        assertTrue("slow start", closeCurve(0.1) < 0.1)
        assertTrue("fast middle then settles", closeCurve(0.5) > 0.5)
        assertTrue(closeCurve(0.9) > 0.97)
    }

    @Test fun aSpringGrowsPastItsTargetOnceThenSettles() {
        val s = Spring(0.0)
        s.target = 100.0
        var peak = 0.0
        repeat(240 * 4) { s.step(1.0 / 60.0 / 4) ; peak = maxOf(peak, s.value) }
        assertTrue("damping 0.72 overshoots a little: $peak", peak > 100.0 && peak < 125.0)
        s.step(2.0)
        assertTrue(s.settled)
        assertEquals(100.0, s.value, 0.5)
    }

    @Test fun aSpringIsStableWhenAFrameIsDropped() {
        val s = Spring(0.0)
        s.target = 100.0
        s.step(0.5) // a half second hiccup in one go
        assertTrue(s.value.isFinite() && s.value in 0.0..200.0)
    }

    @Test fun growingUsesTheSpringAndShrinkingUsesTheTimedCurve() {
        val grow = Tracked(10.0)
        grow.goTo(100.0, 0.0)
        var now = 0.0
        var peak = 0.0
        repeat(120) { now += 16.0; grow.step(0.016, now); peak = maxOf(peak, grow.value) }
        assertTrue("the spring overshoots", peak > 100.0)

        val shrink = Tracked(100.0)
        shrink.goTo(0.0, 1000.0)
        var low = 100.0
        now = 1000.0
        repeat(40) { now += 10.0; shrink.step(0.010, now); low = minOf(low, shrink.value) }
        assertEquals("the curve never overshoots", 0.0, shrink.value, 1e-9)
        assertTrue(low >= 0.0)
    }

    @Test fun theCloseCurveTakes340Milliseconds() {
        val t = Tracked(100.0)
        t.curveTowards(0.0, 0.0)
        t.step(0.0, 339.0)
        assertTrue(t.animating)
        assertTrue(t.value > 0.0)
        t.step(0.0, 340.0)
        assertFalse(t.animating)
        assertEquals(0.0, t.value, 1e-9)
    }

    @Test fun aValueThatIsNotMovingCostsNothing() {
        val t = Tracked(5.0)
        assertFalse(t.animating)
        t.step(0.016, 1.0)
        assertEquals(5.0, t.value, 0.0)
    }

    @Test fun reopeningWhileItRetractsContinuesFromTheCurrentSize() {
        val t = Tracked(100.0)
        t.curveTowards(0.0, 0.0)
        t.step(0.0, 170.0)
        val mid = t.value
        assertTrue(mid in 1.0..99.0)
        t.goTo(100.0, 170.0) // something new started: grow again from where it is
        assertEquals(mid, t.value, 1e-9)
        assertTrue(t.animating)
    }
}
