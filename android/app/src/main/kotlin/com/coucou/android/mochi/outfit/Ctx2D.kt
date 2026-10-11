package com.coucou.android.mochi.outfit

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.hypot
import kotlin.math.tan

/**
 * A small stateful 2D context shaped like the browser's CanvasRenderingContext2D, so the outfit drawing of
 * windows/src/mochi/outfits.ts can be ported line by line. Pure Kotlin: the real drawing is done by a [Gfx]
 * (Compose canvas on the phone, a recorder in the tests, which compare it with the TypeScript original).
 */

/** A colour as the browser reads it: channels 0..255, alpha 0..1. */
data class Rgba(val r: Double, val g: Double, val b: Double, val a: Double)

sealed interface Style
data class Solid(val c: Rgba) : Style
data class Stop(val offset: Double, val c: Rgba)
data class LinearGradient(val x0: Double, val y0: Double, val x1: Double, val y1: Double, val stops: List<Stop>) : Style
data class RadialGradient(val x: Double, val y: Double, val r0: Double, val r1: Double, val stops: List<Stop>) : Style

enum class Cap { BUTT, ROUND }
enum class Join { MITER, ROUND }

/** CSS colours as used by the outfits: #RGB, #RRGGBB, rgb() and rgba(). Anything else is a programming error. */
object Css {
    private val cache = HashMap<String, Rgba>()

    fun parse(s: String): Rgba = cache.getOrPut(s) { parseUncached(s) }

    private fun parseUncached(s: String): Rgba {
        val t = s.trim()
        if (t.startsWith("#")) {
            val h = t.drop(1)
            return when (h.length) {
                3 -> Rgba(h.substring(0, 1).repeat(2).toInt(16).toDouble(), h.substring(1, 2).repeat(2).toInt(16).toDouble(), h.substring(2, 3).repeat(2).toInt(16).toDouble(), 1.0)
                6 -> Rgba(h.substring(0, 2).toInt(16).toDouble(), h.substring(2, 4).toInt(16).toDouble(), h.substring(4, 6).toInt(16).toDouble(), 1.0)
                else -> throw IllegalArgumentException("colour $s")
            }
        }
        val open = t.indexOf('(')
        require(open > 0 && t.endsWith(")")) { "colour $s" }
        val parts = t.substring(open + 1, t.length - 1).split(',').map { it.trim().toDouble() }
        return when (t.substring(0, open)) {
            "rgb" -> { require(parts.size == 3); Rgba(parts[0], parts[1], parts[2], 1.0) }
            "rgba" -> { require(parts.size == 4); Rgba(parts[0], parts[1], parts[2], parts[3]) }
            else -> throw IllegalArgumentException("colour $s")
        }
    }
}

/** What a path is made of, kept as the browser was told (so a recorder can compare it with the original). */
sealed interface Seg {
    data class MoveTo(val x: Double, val y: Double) : Seg
    data class LineTo(val x: Double, val y: Double) : Seg
    data class QuadTo(val cx: Double, val cy: Double, val x: Double, val y: Double) : Seg
    data class CubicTo(val c1x: Double, val c1y: Double, val c2x: Double, val c2y: Double, val x: Double, val y: Double) : Seg
    data class ArcTo(val x1: Double, val y1: Double, val x2: Double, val y2: Double, val r: Double) : Seg
    data class Arc(val x: Double, val y: Double, val r: Double, val a0: Double, val a1: Double) : Seg
    data class Ellipse(val x: Double, val y: Double, val rx: Double, val ry: Double, val rot: Double, val a0: Double, val a1: Double) : Seg
    data class Rect(val x: Double, val y: Double, val w: Double, val h: Double) : Seg
    data object Close : Seg
}

class Path2D {
    val segs = ArrayList<Seg>()
    fun moveTo(x: Double, y: Double) { segs.add(Seg.MoveTo(x, y)) }
    fun lineTo(x: Double, y: Double) { segs.add(Seg.LineTo(x, y)) }
    fun quadraticCurveTo(cx: Double, cy: Double, x: Double, y: Double) { segs.add(Seg.QuadTo(cx, cy, x, y)) }
    fun bezierCurveTo(c1x: Double, c1y: Double, c2x: Double, c2y: Double, x: Double, y: Double) { segs.add(Seg.CubicTo(c1x, c1y, c2x, c2y, x, y)) }
    fun arcTo(x1: Double, y1: Double, x2: Double, y2: Double, r: Double) { segs.add(Seg.ArcTo(x1, y1, x2, y2, r)) }
    fun arc(x: Double, y: Double, r: Double, a0: Double, a1: Double) { segs.add(Seg.Arc(x, y, r, a0, a1)) }
    fun ellipse(x: Double, y: Double, rx: Double, ry: Double, rot: Double, a0: Double, a1: Double) { segs.add(Seg.Ellipse(x, y, rx, ry, rot, a0, a1)) }
    fun rect(x: Double, y: Double, w: Double, h: Double) { segs.add(Seg.Rect(x, y, w, h)) }
    fun closePath() { segs.add(Seg.Close) }
    fun addPath(p: Path2D) { segs.addAll(p.segs) }
}

/** The drawing surface: transforms, clips and filled or stroked paths, plus one translucent layer. */
interface Gfx {
    fun save()
    fun restore()
    fun translate(x: Double, y: Double)
    fun scale(x: Double, y: Double)
    fun rotate(angle: Double)
    fun clip(path: Path2D, evenOdd: Boolean)
    fun fill(path: Path2D, style: Style)
    fun stroke(path: Path2D, style: Style, width: Double, cap: Cap, join: Join)
    /** Draws what [block] draws as one picture at [alpha], so overlapping parts do not show through each other. */
    fun layer(alpha: Double, block: () -> Unit)
}

class Ctx2D(private val gfx: Gfx) {
    private class State(val fill: Style, val stroke: Style, val width: Double, val cap: Cap, val join: Join)

    var fillStyle: Style = Solid(Rgba(0.0, 0.0, 0.0, 1.0))
    var strokeStyle: Style = Solid(Rgba(0.0, 0.0, 0.0, 1.0))
    var lineWidth = 1.0
    var lineCap = Cap.BUTT
    var lineJoin = Join.MITER
    private var current = Path2D()
    private val stack = ArrayList<State>()

    fun fillStyle(css: String) { fillStyle = Solid(Css.parse(css)) }
    fun strokeStyle(css: String) { strokeStyle = Solid(Css.parse(css)) }

    fun save() { stack.add(State(fillStyle, strokeStyle, lineWidth, lineCap, lineJoin)); gfx.save() }
    fun restore() {
        val s = stack.removeLastOrNull() ?: return
        fillStyle = s.fill; strokeStyle = s.stroke; lineWidth = s.width; lineCap = s.cap; lineJoin = s.join
        gfx.restore()
    }
    fun translate(x: Double, y: Double) = gfx.translate(x, y)
    fun scale(x: Double, y: Double) = gfx.scale(x, y)
    fun rotate(a: Double) = gfx.rotate(a)

    // The current path, as the browser keeps one between beginPath() and fill() or stroke().
    fun beginPath() { current = Path2D() }
    fun moveTo(x: Double, y: Double) = current.moveTo(x, y)
    fun lineTo(x: Double, y: Double) = current.lineTo(x, y)
    fun quadraticCurveTo(cx: Double, cy: Double, x: Double, y: Double) = current.quadraticCurveTo(cx, cy, x, y)
    fun bezierCurveTo(c1x: Double, c1y: Double, c2x: Double, c2y: Double, x: Double, y: Double) = current.bezierCurveTo(c1x, c1y, c2x, c2y, x, y)
    fun arcTo(x1: Double, y1: Double, x2: Double, y2: Double, r: Double) = current.arcTo(x1, y1, x2, y2, r)
    fun arc(x: Double, y: Double, r: Double, a0: Double, a1: Double) = current.arc(x, y, r, a0, a1)
    fun ellipse(x: Double, y: Double, rx: Double, ry: Double, rot: Double, a0: Double, a1: Double) = current.ellipse(x, y, rx, ry, rot, a0, a1)
    fun closePath() = current.closePath()

    fun fill(path: Path2D = current) = gfx.fill(path, fillStyle)
    fun stroke(path: Path2D = current) = gfx.stroke(path, strokeStyle, lineWidth, lineCap, lineJoin)
    fun clip(path: Path2D, evenOdd: Boolean = false) = gfx.clip(path, evenOdd)
    fun fillRect(x: Double, y: Double, w: Double, h: Double) = gfx.fill(Path2D().also { it.rect(x, y, w, h) }, fillStyle)

    fun createLinearGradient(x0: Double, y0: Double, x1: Double, y1: Double, stops: List<Pair<Double, String>>): Style =
        LinearGradient(x0, y0, x1, y1, stops.map { Stop(it.first, Css.parse(it.second)) })

    fun createRadialGradient(x: Double, y: Double, r0: Double, r1: Double, stops: List<Pair<Double, String>>): Style =
        RadialGradient(x, y, r0, r1, stops.map { Stop(it.first, Css.parse(it.second)) })

    /** Draws [fn] at [alpha] as one layer (a plain save/restore when it is practically opaque). */
    fun withLayer(alpha: Double, fn: (Ctx2D) -> Unit) {
        if (alpha >= 0.999) {
            save(); fn(this); restore()
            return
        }
        gfx.layer(alpha) { save(); fn(this); restore() }
    }
}

/**
 * The browser's arcTo(): where the line from the current point stops, the circle's centre and its sweep.
 * Null when the three points are in line or the radius is zero: the browser then just draws a line to (x1, y1).
 */
object ArcToMath {
    class Arc(val startX: Double, val startY: Double, val endX: Double, val endY: Double, val cx: Double, val cy: Double, val r: Double, val startAngle: Double, val sweep: Double)

    fun compute(x0: Double, y0: Double, x1: Double, y1: Double, x2: Double, y2: Double, r: Double): Arc? {
        if (r <= 0) return null
        val ax = x0 - x1
        val ay = y0 - y1
        val bx = x2 - x1
        val by = y2 - y1
        val la = hypot(ax, ay)
        val lb = hypot(bx, by)
        if (la < 1e-12 || lb < 1e-12) return null
        val cross = ax * by - ay * bx
        if (abs(cross) < 1e-12 * la * lb) return null
        val dot = ax * bx + ay * by
        val angle = atan2(abs(cross), dot) // angle at the corner, 0..PI
        val t = r / tan(angle / 2)
        val sx = x1 + ax / la * t
        val sy = y1 + ay / la * t
        val ex = x1 + bx / lb * t
        val ey = y1 + by / lb * t
        // The centre lies on the bisector, at distance r from both tangent points.
        val mx = (ax / la + bx / lb)
        val my = (ay / la + by / lb)
        val ml = hypot(mx, my)
        val d = r / kotlin.math.sin(angle / 2)
        val cx = x1 + mx / ml * d
        val cy = y1 + my / ml * d
        val a0 = atan2(sy - cy, sx - cx)
        var sweep = atan2(ey - cy, ex - cx) - a0
        // Take the short way round.
        while (sweep > PI) sweep -= 2 * PI
        while (sweep < -PI) sweep += 2 * PI
        return Arc(sx, sy, ex, ey, cx, cy, r, a0, sweep)
    }
}
