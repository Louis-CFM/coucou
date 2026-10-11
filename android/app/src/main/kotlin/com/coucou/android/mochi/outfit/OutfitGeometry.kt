package com.coucou.android.mochi.outfit

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sign
import kotlin.math.sin

/**
 * The head's 3D helpers of windows/src/mochi/outfits.ts. Body space: origin at the body centre, y down,
 * R = width x 0.3, rx = 1.14 R, ry = 0.88 R. The head is a superellipsoid, so its silhouette matches Mochi's body.
 */
const val EXP = 2.7
const val VIEW_TILT = -0.3
const val ACC_PITCH = 0.4
const val EYE_W = 0.25
const val EYE_H = 0.27
const val EYE_SP = 0.37
const val EYE_P = -0.12

/** Below this radius the small details (ribs, dots, gems) are left out. */
const val SIMPLIFY_BELOW_R = 16.0

data class Vec3(val x: Double, val y: Double, val z: Double)
data class P3(val x: Double, val y: Double, val z: Double)
data class Pt2(val x: Double, val y: Double)

/** Head geometry plus the spring lag of the soft parts (-1..1, in head units). */
data class Head(val R: Double, val rx: Double, val ry: Double, val yaw: Double, val pitch: Double, val physDx: Double, val physDy: Double)

fun makeHead(R: Double, yaw: Double = 0.0, pitch: Double = 0.0, physDx: Double = 0.0, physDy: Double = 0.0) =
    Head(R, R * 1.14, R * 0.88, yaw, pitch, physDx, physDy)

/** Radius of the horizontal ring of the head at height y. */
fun ringR(y: Double): Double {
    val a = min(1.0, abs(y))
    return (1 - a.pow(EXP)).pow(1 / EXP)
}

/** Head-local point (x right, y up, z toward the viewer) to body space, with depth. */
fun proj(h: Head, x: Double, y: Double, z: Double): P3 {
    val cy = cos(h.yaw)
    val sy = sin(h.yaw)
    val x1 = x * cy + z * sy
    val z1 = -x * sy + z * cy
    val pitch = VIEW_TILT + h.pitch * ACC_PITCH
    val cp = cos(pitch)
    val sp = sin(pitch)
    val y2 = y * cp + z1 * sp
    val z2 = -y * sp + z1 * cp
    return P3(x1 * h.rx, -y2 * h.ry, z2)
}

fun proj(h: Head, v: Vec3) = proj(h, v.x, v.y, v.z)

/** Point on the head surface at height y, longitude lon (0 = facing the viewer), scaled by s. */
fun surf(y: Double, lon: Double, s: Double = 1.0): Vec3 {
    val r = ringR(y) * s
    return Vec3(r * sin(lon), y, r * cos(lon))
}

/** The visible half of a projected closed ring, left to right, cut at its silhouette. */
fun frontSilhouette(pts: List<P3>): List<P3> {
    val n = pts.size
    if (n < 2) return pts
    var minI = 0
    var maxI = 0
    for (i in 1 until n) {
        if (pts[i].x < pts[minI].x) minI = i
        if (pts[i].x > pts[maxI].x) maxI = i
    }
    if (minI == maxI) return listOf(pts[minI])
    fun walk(step: Int): List<P3> {
        val out = ArrayList<P3>()
        var i = minI
        while (true) {
            out.add(pts[i])
            if (i == maxI || out.size > n) break
            i = (i + step + n) % n
        }
        return out
    }
    val a = walk(1)
    val b = walk(-1)
    val za = a.sumOf { it.z } / a.size
    val zb = b.sumOf { it.z } / b.size
    return if (za >= zb) a else b
}

fun ring(h: Head, y: Double, s: Double, n: Int = 120): List<P3> =
    (0 until n).map { i -> proj(h, surf(y, -PI + i.toDouble() / n * 2 * PI, s)) }

/** Front arc of the ring at height y, ordered left to right. */
fun frontArc(h: Head, y: Double, s: Double): List<P3> = frontSilhouette(ring(h, y, s))

/** The part of the head above the front arc of ring y: what a cap covers. */
fun capClip(h: Head, y: Double, s: Double, extraTop: Double = 3.0): Path2D {
    val arc = frontArc(h, y, s)
    val p = Path2D()
    if (arc.isEmpty()) return p
    p.moveTo(arc[0].x - h.rx, arc[0].y)
    for (q in arc) p.lineTo(q.x, q.y)
    val last = arc[arc.size - 1]
    p.lineTo(last.x + h.rx, last.y)
    p.lineTo(h.rx * 2, -h.ry * extraTop)
    p.lineTo(-h.rx * 2, -h.ry * extraTop)
    p.closePath()
    return p
}

/** Everything but [p], for an even-odd clip. */
fun invert(p: Path2D, h: Head): Path2D {
    val q = Path2D()
    q.rect(-h.rx * 4, -h.ry * 4, h.rx * 8, h.ry * 8)
    q.addPath(p)
    return q
}

/** Mochi's body outline, the same superellipse as the engine. */
fun bodyOutline(rx: Double, ry: Double): Path2D {
    val p = Path2D()
    val n = 96
    val e = 2 / EXP
    for (i in 0..n) {
        val a = i.toDouble() / n * PI * 2
        val ca = cos(a)
        val sa = sin(a)
        val x = rx * sign(ca) * abs(ca).pow(e)
        val y = ry * sign(sa) * abs(sa).pow(e)
        if (i == 0) p.moveTo(x, y) else p.lineTo(x, y)
    }
    p.closePath()
    return p
}

data class EyeFrame(val sd: Double, val x: Double, val y: Double, val fx: Double, val fy: Double, val visible: Boolean, val w: Double, val h: Double)

/** Where the engine draws the eyes: the glasses sit on these. */
fun eyeFrames(h: Head): List<EyeFrame> = listOf(-1.0, 1.0).map { sd ->
    val eyeYaw = sd * EYE_SP + h.yaw
    val eyePitch = EYE_P + h.pitch
    val cp = cos(eyePitch)
    EyeFrame(
        sd = sd,
        visible = cos(eyeYaw) * cp > 0.04,
        x = sin(eyeYaw) * cp * h.rx,
        y = -sin(eyePitch) * h.ry,
        fx = max(0.18, cos(eyeYaw)),
        fy = max(0.18, cp),
        w = h.R * EYE_W,
        h = h.R * EYE_H,
    )
}
