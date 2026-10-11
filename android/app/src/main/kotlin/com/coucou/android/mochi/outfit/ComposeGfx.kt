package com.coucou.android.mochi.outfit

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Canvas
import androidx.compose.ui.graphics.ClipOp
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.LinearGradientShader
import androidx.compose.ui.graphics.Matrix
import androidx.compose.ui.graphics.Paint
import androidx.compose.ui.graphics.PaintingStyle
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.RadialGradientShader
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.max

/**
 * Draws what the outfit code asks for (see [Ctx2D]) on a Compose canvas. [bounds] is the area a translucent layer
 * covers (the whole Mochi view is enough).
 */
class ComposeGfx(private val c: Canvas, private val bounds: Rect) : Gfx {
    private val paint = Paint().apply { isAntiAlias = true }

    override fun save() = c.save()
    override fun restore() = c.restore()
    override fun translate(x: Double, y: Double) = c.translate(x.toFloat(), y.toFloat())
    override fun scale(x: Double, y: Double) = c.scale(x.toFloat(), y.toFloat())
    override fun rotate(angle: Double) = c.rotate((angle * 180 / PI).toFloat())

    override fun clip(path: Path2D, evenOdd: Boolean) {
        c.clipPath(toPath(path, evenOdd), ClipOp.Intersect)
    }

    override fun fill(path: Path2D, style: Style) {
        paint.style = PaintingStyle.Fill
        paint.alpha = 1f
        paint.shader = null
        setStyle(style)
        c.drawPath(toPath(path, false), paint)
        paint.shader = null
    }

    override fun stroke(path: Path2D, style: Style, width: Double, cap: Cap, join: Join) {
        paint.style = PaintingStyle.Stroke
        paint.alpha = 1f
        paint.shader = null
        paint.strokeWidth = width.toFloat()
        paint.strokeCap = if (cap == Cap.ROUND) StrokeCap.Round else StrokeCap.Butt
        paint.strokeJoin = if (join == Join.ROUND) StrokeJoin.Round else StrokeJoin.Miter
        setStyle(style)
        c.drawPath(toPath(path, false), paint)
        paint.shader = null
        paint.style = PaintingStyle.Fill
    }

    override fun layer(alpha: Double, block: () -> Unit) {
        val p = Paint().apply { this.alpha = alpha.toFloat().coerceIn(0f, 1f) }
        c.saveLayer(bounds, p)
        block()
        c.restore()
    }

    private fun color(x: Rgba) = Color(
        (x.r / 255).toFloat().coerceIn(0f, 1f), (x.g / 255).toFloat().coerceIn(0f, 1f),
        (x.b / 255).toFloat().coerceIn(0f, 1f), x.a.toFloat().coerceIn(0f, 1f),
    )

    private fun setStyle(style: Style) {
        when (style) {
            is Solid -> paint.color = color(style.c)
            is LinearGradient -> {
                paint.color = Color.Black
                paint.shader = LinearGradientShader(
                    Offset(style.x0.toFloat(), style.y0.toFloat()), Offset(style.x1.toFloat(), style.y1.toFloat()),
                    style.stops.map { color(it.c) }, style.stops.map { it.offset.toFloat() },
                )
            }
            is RadialGradient -> {
                paint.color = Color.Black
                // A circle that starts at r0 > 0 shows the first colour inside r0 and the ramp from there: shift the stops.
                val r1 = max(style.r1, 0.001)
                val k = (style.r0 / r1).coerceIn(0.0, 1.0)
                val stops = if (k > 0) listOf(Stop(0.0, style.stops.first().c)) + style.stops.map { Stop(k + it.offset * (1 - k), it.c) } else style.stops
                paint.shader = RadialGradientShader(
                    Offset(style.x.toFloat(), style.y.toFloat()), r1.toFloat(),
                    stops.map { color(it.c) }, stops.map { it.offset.toFloat() },
                )
            }
        }
    }

    companion object {
        /** The path as a Compose path; the browser's arcTo, arc and ellipse are turned into arcs here. */
        fun toPath(p: Path2D, evenOdd: Boolean): Path {
            val out = Path()
            out.fillType = if (evenOdd) PathFillType.EvenOdd else PathFillType.NonZero
            var cx = 0.0
            var cy = 0.0
            var sx = 0.0
            var sy = 0.0
            for (s in p.segs) {
                when (s) {
                    is Seg.MoveTo -> { out.moveTo(s.x.toFloat(), s.y.toFloat()); cx = s.x; cy = s.y; sx = s.x; sy = s.y }
                    is Seg.LineTo -> { out.lineTo(s.x.toFloat(), s.y.toFloat()); cx = s.x; cy = s.y }
                    is Seg.QuadTo -> { out.quadraticBezierTo(s.cx.toFloat(), s.cy.toFloat(), s.x.toFloat(), s.y.toFloat()); cx = s.x; cy = s.y }
                    is Seg.CubicTo -> {
                        out.cubicTo(s.c1x.toFloat(), s.c1y.toFloat(), s.c2x.toFloat(), s.c2y.toFloat(), s.x.toFloat(), s.y.toFloat())
                        cx = s.x; cy = s.y
                    }
                    is Seg.ArcTo -> {
                        val a = ArcToMath.compute(cx, cy, s.x1, s.y1, s.x2, s.y2, s.r)
                        if (a == null) {
                            out.lineTo(s.x1.toFloat(), s.y1.toFloat()); cx = s.x1; cy = s.y1
                        } else {
                            out.lineTo(a.startX.toFloat(), a.startY.toFloat())
                            out.arcTo(
                                Rect((a.cx - a.r).toFloat(), (a.cy - a.r).toFloat(), (a.cx + a.r).toFloat(), (a.cy + a.r).toFloat()),
                                Math.toDegrees(a.startAngle).toFloat(), Math.toDegrees(a.sweep).toFloat(), false,
                            )
                            cx = a.endX; cy = a.endY
                        }
                    }
                    is Seg.Arc -> {
                        addEllipse(out, s.x, s.y, s.r, s.r, 0.0, s.a0, s.a1)
                        cx = s.x + s.r * kotlin.math.cos(s.a1); cy = s.y + s.r * kotlin.math.sin(s.a1)
                    }
                    is Seg.Ellipse -> {
                        addEllipse(out, s.x, s.y, s.rx, s.ry, s.rot, s.a0, s.a1)
                        cx = s.x; cy = s.y
                    }
                    is Seg.Rect -> {
                        out.addRect(Rect(s.x.toFloat(), s.y.toFloat(), (s.x + s.w).toFloat(), (s.y + s.h).toFloat()))
                        cx = s.x; cy = s.y; sx = s.x; sy = s.y
                    }
                    Seg.Close -> { out.close(); cx = sx; cy = sy }
                }
            }
            return out
        }

        private fun addEllipse(out: Path, x: Double, y: Double, rx: Double, ry: Double, rot: Double, a0: Double, a1: Double) {
            val oval = Rect((x - rx).toFloat(), (y - ry).toFloat(), (x + rx).toFloat(), (y + ry).toFloat())
            val part = Path()
            if (abs(a1 - a0) >= 2 * PI - 1e-9) part.addOval(oval)
            else part.arcTo(oval, Math.toDegrees(a0).toFloat(), Math.toDegrees(a1 - a0).toFloat(), true)
            if (rot != 0.0) {
                val m = Matrix()
                m.translate(x.toFloat(), y.toFloat())
                m.rotateZ(Math.toDegrees(rot).toFloat())
                m.translate(-x.toFloat(), -y.toFloat())
                part.transform(m)
            }
            out.addPath(part)
        }
    }
}
