package com.coucou.android.mochi.outfit

import com.coucou.android.core.Ease
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin

/**
 * Mochi's outfits, a line-by-line port of windows/src/mochi/outfits.ts (itself a port of the Mac's
 * MochiOutfitDrawing.swift). Coordinates are the body space of [Head]. Every function keeps the order of
 * its drawing calls, because a test records them and compares with the TypeScript original.
 */
internal typealias Stops = List<Pair<Double, String>>

internal fun Ctx2D.lin(x0: Double, y0: Double, x1: Double, y1: Double, stops: Stops) = createLinearGradient(x0, y0, x1, y1, stops)
internal fun Ctx2D.rad(x: Double, y: Double, r0: Double, r1: Double, stops: Stops) = createRadialGradient(x, y, r0, max(0.001, r1), stops)

internal fun Ctx2D.polyline(pts: List<Pt2>) {
    beginPath()
    pts.forEachIndexed { i, q -> if (i > 0) lineTo(q.x, q.y) else moveTo(q.x, q.y) }
}

internal fun Ctx2D.roundRect(x: Double, y: Double, w: Double, h: Double, r: Double) {
    val rr = max(0.0, min(r, min(w / 2, h / 2)))
    beginPath()
    moveTo(x + rr, y)
    arcTo(x + w, y, x + w, y + h, rr)
    arcTo(x + w, y + h, x, y + h, rr)
    arcTo(x, y + h, x, y, rr)
    arcTo(x, y, x + w, y, rr)
    closePath()
}

internal fun Ctx2D.fillAll(h: Head) = fillRect(-h.rx * 4, -h.ry * 4, h.rx * 8, h.ry * 8)

internal fun List<P3>.pts() = map { Pt2(it.x, it.y) }

// ── Soft bits ─────────────────────────────────────────────────────────────────

internal fun pompom(ctx: Ctx2D, x: Double, y: Double, r: Double, base: String = "#FFFFFF", shade: String = "#D5D9E2") {
    ctx.save()
    ctx.translate(x, y)
    val n = 11
    for (i in 0 until n) {
        val a = i.toDouble() / n * PI * 2
        val br = r * (0.34 + 0.06 * sin(i * 2.3))
        val bx = cos(a) * r * 0.78
        val by = sin(a) * r * 0.78
        ctx.fillStyle = ctx.rad(bx - br * 0.4, by - br * 0.5, 0.0, br * 1.3, listOf(0.0 to base, 1.0 to shade))
        ctx.beginPath()
        ctx.arc(bx, by, br, 0.0, PI * 2)
        ctx.fill()
    }
    ctx.fillStyle = ctx.rad(-r * 0.3, -r * 0.35, 0.0, r * 1.05, listOf(0.0 to base, 0.7 to base, 1.0 to shade))
    ctx.beginPath()
    ctx.arc(0.0, 0.0, r * 0.86, 0.0, PI * 2)
    ctx.fill()
    ctx.restore()
}

/** Fuzzy band along a polyline (the Santa hat's trim). */
internal fun fuzzyBand(ctx: Ctx2D, arc: List<Pt2>, thick: Double, base: String = "#FFFFFF", shade: String = "#DADDE4") {
    if (arc.size < 2) return
    ctx.save()
    ctx.lineJoin = Join.ROUND
    ctx.lineCap = Cap.ROUND
    ctx.polyline(arc)
    ctx.strokeStyle(shade)
    ctx.lineWidth = thick
    ctx.stroke()
    ctx.polyline(arc)
    ctx.strokeStyle(base)
    ctx.lineWidth = thick * 0.78
    ctx.stroke()
    val step = max(2, floor(arc.size / 16.0).toInt())
    var i = 0
    while (i < arc.size) {
        val q = arc[i]
        val r = thick * (0.32 + 0.1 * sin(i * 1.7))
        ctx.fillStyle = ctx.rad(q.x - r * 0.3, q.y - thick * 0.35 - r * 0.3, 0.0, r * 1.2, listOf(0.0 to base, 1.0 to shade))
        ctx.beginPath()
        ctx.arc(q.x, q.y - thick * 0.32, r, 0.0, PI * 2)
        ctx.fill()
        i += step
    }
    ctx.restore()
}

// ── Beanie ────────────────────────────────────────────────────────────────────
