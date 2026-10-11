package com.coucou.android.mochi

import com.coucou.android.core.lerp
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

data class Pt(val x: Double, val y: Double)

object MochiGeometry {
    const val BODY_SEGMENTS = 72
    private const val EXP_N = 2.0 / 2.7

    /** Ray to rounded-rect boundary intersection, for the mailbox morph (engine.ts rrPoint). */
    fun rrPoint(ca: Double, sa: Double, w: Double, h: Double, cr: Double): Pt {
        val eps = 1e-6
        val kx = if (ca >= 0) 1.0 else -1.0
        val ky = if (sa >= 0) 1.0 else -1.0
        val cx = kx * (w - cr)
        val cy = ky * (h - cr)

        val dot = ca * cx + sa * cy
        val disc = dot * dot - (cx * cx + cy * cy - cr * cr)
        if (disc >= 0) {
            val t = dot + sqrt(disc)
            if (t > eps) {
                val px = ca * t
                val py = sa * t
                if (abs(px) >= w - cr - eps && abs(py) >= h - cr - eps) return Pt(px, py)
            }
        }
        if (abs(sa) > eps) {
            val t = (ky * h) / sa
            if (t > eps) {
                val px = ca * t
                if (abs(px) <= w - cr + eps) return Pt(px, ky * h)
            }
        }
        if (abs(ca) > eps) {
            val t = (kx * w) / ca
            if (t > eps) {
                val py = sa * t
                if (abs(py) <= h - cr + eps) return Pt(kx * w, py)
            }
        }
        return Pt(kx * w, ky * h)
    }

    /** Superellipse (exponent 2.7) blended with the mailbox box by `morph`. */
    fun bodyPoints(rx: Double, ry: Double, r: Double, morph: Double): List<Pt> {
        val tw = r * 1.0
        val th = r * 0.94
        val tr = r * 0.42
        return (0..BODY_SEGMENTS).map { i ->
            val a = i.toDouble() / BODY_SEGMENTS * PI * 2
            val ca = cos(a)
            val sa = sin(a)
            val px0 = rx * (if (ca >= 0) ca.pow(EXP_N) else -(-ca).pow(EXP_N))
            val py0 = ry * (if (sa >= 0) sa.pow(EXP_N) else -(-sa).pow(EXP_N))
            if (morph >= 0.005) {
                val rr = rrPoint(ca, sa, tw, th, tr)
                Pt(lerp(px0, rr.x, morph), lerp(py0, rr.y, morph))
            } else {
                Pt(px0, py0)
            }
        }
    }
}
