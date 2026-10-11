package com.coucou.android.mochi.outfit

import kotlin.math.PI
import kotlin.math.abs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class Ctx2DTest {
    @Test fun cssColoursAreReadLikeTheBrowserDoes() {
        assertEquals(Rgba(255.0, 255.0, 255.0, 1.0), Css.parse("#FFFFFF"))
        assertEquals(Rgba(17.0, 34.0, 51.0, 1.0), Css.parse("#123"))
        assertEquals(Rgba(26.0, 20.0, 18.0, 1.0), Css.parse("rgb(26,20,18)"))
        assertEquals(Rgba(17.0, 19.0, 23.0, 0.82), Css.parse("rgba(17,19,23,0.82)"))
        assertEquals(Rgba(150.0, 50.0, 0.0, 1.0E-7), Css.parse("rgba(150,50,0,1e-7)"))
        assertEquals(Rgba(0.0, 0.0, 0.0, 0.0), Css.parse(" rgba( 0 , 0 , 0 , 0 ) "))
    }

    @Test fun arcToRoundsACornerTheWayTheBrowserDoes() {
        // A square corner at (10, 0), coming from (0, 0), going down to (10, 10), radius 2.
        val a = ArcToMath.compute(0.0, 0.0, 10.0, 0.0, 10.0, 10.0, 2.0)
        assertNotNull(a)
        assertEquals(8.0, a!!.startX, 1e-9); assertEquals(0.0, a.startY, 1e-9)
        assertEquals(10.0, a.endX, 1e-9); assertEquals(2.0, a.endY, 1e-9)
        assertEquals(8.0, a.cx, 1e-9); assertEquals(2.0, a.cy, 1e-9)
        assertEquals(PI / 2, a.sweep, 1e-9) // clockwise on screen (y down)
    }

    @Test fun arcToTurnsTheOtherWayForTheOtherCorner() {
        val a = ArcToMath.compute(10.0, 0.0, 0.0, 0.0, 0.0, 10.0, 3.0)!!
        assertEquals(-PI / 2, a.sweep, 1e-9)
        assertEquals(3.0, a.cx, 1e-9); assertEquals(3.0, a.cy, 1e-9)
    }

    @Test fun arcToWithNoCornerIsALine() {
        assertNull(ArcToMath.compute(0.0, 0.0, 5.0, 0.0, 10.0, 0.0, 2.0))
        assertNull(ArcToMath.compute(0.0, 0.0, 5.0, 0.0, 10.0, 5.0, 0.0))
        assertNull(ArcToMath.compute(0.0, 0.0, 0.0, 0.0, 10.0, 5.0, 1.0))
    }

    @Test fun anAcuteCornerKeepsTheTangentPointsAtEqualDistance() {
        val a = ArcToMath.compute(0.0, 0.0, 10.0, 0.0, 0.0, 4.0, 1.5)!!
        val d1 = Math.hypot(a.startX - 10.0, a.startY - 0.0)
        val d2 = Math.hypot(a.endX - 10.0, a.endY - 0.0)
        assertTrue(abs(d1 - d2) < 1e-9)
        assertEquals(1.5, Math.hypot(a.startX - a.cx, a.startY - a.cy), 1e-9)
        assertEquals(1.5, Math.hypot(a.endX - a.cx, a.endY - a.cy), 1e-9)
    }

    @Test fun styleStateComesBackAfterRestore() {
        val ctx = Ctx2D(RecGfx())
        ctx.fillStyle("#FF0000"); ctx.lineWidth = 3.0; ctx.lineCap = Cap.ROUND
        ctx.save()
        ctx.fillStyle("#00FF00"); ctx.lineWidth = 9.0; ctx.lineCap = Cap.BUTT
        ctx.restore()
        assertEquals(Solid(Rgba(255.0, 0.0, 0.0, 1.0)), ctx.fillStyle)
        assertEquals(3.0, ctx.lineWidth, 0.0)
        assertEquals(Cap.ROUND, ctx.lineCap)
    }

    @Test fun anAlmostOpaqueLayerIsAPlainSave() {
        val rec = RecGfx()
        Ctx2D(rec).withLayer(0.9995) { it.translate(1.0, 2.0) }
        assertEquals("""[["save"],["translate",1,2],["restore"]]""", rec.result().toString())
        val rec2 = RecGfx()
        Ctx2D(rec2).withLayer(0.5) { it.translate(1.0, 2.0) }
        assertEquals("""[["layer",0.5,[["save"],["translate",1,2],["restore"]]]]""", rec2.result().toString())
    }
}
