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

// Beanie, Santa hat, party hat, crown, witch hat: parts of the port in Outfits.kt.

internal fun beanie(ctx: Ctx2D, h: Head, body: Path2D, simple: Boolean) {
    val s = 1.035
    val yEdge = 0.42
    val yCuff = 0.58
    val head = bodyOutline(h.rx * s, h.ry * s)

    // shadow on the head under the cuff
    ctx.save()
    ctx.clip(body)
    ctx.clip(capClip(h, yEdge - 0.12, 1.0))
    ctx.fillStyle("rgba(30,40,70,0.10)")
    ctx.fillAll(h)
    ctx.restore()

    // knit body
    ctx.save()
    ctx.clip(capClip(h, yCuff, s))
    ctx.fillStyle = ctx.lin(h.rx * 0.5, -h.ry * 1.1, -h.rx * 0.6, h.ry * 0.2, listOf(0.0 to "#7DB6FF", 1.0 to "#2F6FE0"))
    ctx.fill(head)
    if (!simple) {
        ctx.clip(head)
        ctx.strokeStyle("rgba(20,50,140,0.16)")
        ctx.lineWidth = h.R * 0.045
        ctx.lineCap = Cap.ROUND
        for (k in -6..6) {
            val lon = k * 0.24
            val pts = ArrayList<P3>()
            for (i in 0..16) {
                val q = proj(h, surf(yCuff + (1.05 - yCuff) * i / 16, lon, s))
                if (q.z > 0) pts.add(q)
            }
            if (pts.size < 2) continue
            ctx.polyline(pts.pts())
            ctx.stroke()
        }
    }
    ctx.restore()

    // cuff: the band between yEdge and yCuff
    val cuffHead = bodyOutline(h.rx * s * 1.04, h.ry * s * 1.04)
    ctx.save()
    ctx.clip(capClip(h, yEdge, s * 1.04))
    ctx.clip(invert(capClip(h, yCuff, s * 1.04), h), true)
    ctx.fillStyle = ctx.lin(0.0, -h.ry * 0.6, 0.0, -h.ry * 0.2, listOf(0.0 to "#3C7BEA", 1.0 to "#2257C4"))
    ctx.fill(cuffHead)
    ctx.clip(cuffHead)
    ctx.strokeStyle("rgba(10,30,100,0.22)")
    ctx.lineWidth = h.R * 0.035
    for (k in -14..14) {
        val lon = k * 0.115
        val a = proj(h, surf(yEdge, lon, s * 1.04))
        val b = proj(h, surf(yCuff, lon, s * 1.04))
        if (a.z < 0) continue
        ctx.beginPath()
        ctx.moveTo(a.x, a.y)
        ctx.lineTo(b.x, b.y)
        ctx.stroke()
    }
    ctx.restore()

    // top highlight
    ctx.save()
    ctx.clip(capClip(h, yCuff, s))
    ctx.clip(head)
    ctx.fillStyle = ctx.rad(h.rx * 0.3, -h.ry * 0.85, 0.0, h.R * 0.45, listOf(0.0 to "rgba(255,255,255,0.35)", 1.0 to "rgba(255,255,255,0)"))
    ctx.fill(head)
    ctx.restore()

    // pompom on a short spring
    val top = proj(h, 0.0, 1.08 * s, 0.0)
    pompom(ctx, top.x + h.physDx * h.rx * 0.25, top.y - h.R * 0.12 + h.physDy * h.ry * 0.15, h.R * 0.24)
}

// ── Santa hat ─────────────────────────────────────────────────────────────────

internal fun santaHat(ctx: Ctx2D, h: Head, body: Path2D) {
    val s = 1.05
    val yEdge = 0.52
    val arc = frontArc(h, yEdge, s)
    if (arc.isEmpty()) return
    val l = arc[0]
    val rt = arc[arc.size - 1]
    val crown = proj(h, 0.0, 1.05, 0.0)
    // the tip flops to the right and down, plus the spring lag
    val tip = Pt2(crown.x + h.rx * (0.95 + h.physDx * 0.35), crown.y + h.ry * (0.05 + h.physDy * 0.2))
    val peak = Pt2(crown.x + h.rx * 0.25, crown.y - h.ry * 0.62)
    val bag = Path2D()
    bag.moveTo(l.x, l.y)
    bag.bezierCurveTo(l.x - h.rx * 0.05, l.y - h.ry * 0.7, peak.x - h.rx * 0.55, peak.y - h.ry * 0.05, peak.x, peak.y)
    bag.quadraticCurveTo(tip.x - h.rx * 0.05, peak.y - h.ry * 0.02, tip.x, tip.y)
    bag.quadraticCurveTo(tip.x - h.rx * 0.12, tip.y - h.ry * 0.22, peak.x + h.rx * 0.18, peak.y + h.ry * 0.32)
    bag.bezierCurveTo(rt.x + h.rx * 0.05, peak.y + h.ry * 0.45, rt.x + h.rx * 0.08, rt.y - h.ry * 0.35, rt.x, rt.y)
    for (i in arc.indices.reversed()) bag.lineTo(arc[i].x, arc[i].y)
    bag.closePath()

    ctx.save()
    ctx.clip(body)
    ctx.clip(capClip(h, yEdge - 0.14, 1.0))
    ctx.fillStyle("rgba(120,10,10,0.10)")
    ctx.fillAll(h)
    ctx.restore()

    ctx.fillStyle = ctx.lin(-h.rx * 0.6, -h.ry * 1.6, h.rx * 0.7, -h.ry * 0.3, listOf(0.0 to "#FF6B6B", 0.55 to "#E53935", 1.0 to "#B71C1C"))
    ctx.fill(bag)

    // folds following the flop
    ctx.save()
    ctx.clip(bag)
    ctx.lineCap = Cap.ROUND
    ctx.strokeStyle("rgba(90,0,0,0.20)")
    for ((a, b, w) in listOf(Triple(0.15, 0.55, 0.1), Triple(0.45, 0.85, 0.08))) {
        ctx.beginPath()
        ctx.moveTo(peak.x - h.rx * 0.1 + (rt.x - l.x) * a * 0.3, peak.y + h.ry * 0.15)
        ctx.quadraticCurveTo(peak.x + h.rx * 0.35, peak.y + h.ry * (0.05 + a * 0.3), tip.x - h.rx * (0.45 - b * 0.3), tip.y - h.ry * 0.12)
        ctx.lineWidth = h.R * w
        ctx.stroke()
    }
    ctx.fillStyle = ctx.rad(peak.x - h.rx * 0.25, peak.y + h.ry * 0.05, 0.0, h.R * 0.5, listOf(0.0 to "rgba(255,255,255,0.32)", 1.0 to "rgba(255,255,255,0)"))
    ctx.fill(bag)
    ctx.restore()

    fuzzyBand(ctx, arc.pts(), h.R * 0.3)
    pompom(ctx, tip.x, tip.y + h.R * 0.04, h.R * 0.22)
}

// ── Party hat ─────────────────────────────────────────────────────────────────

internal fun partyHat(ctx: Ctx2D, h: Head, simple: Boolean) {
    val baseY = 0.82
    val baseR = 0.42
    val lean = -0.24 + h.physDx * 0.12
    val c = proj(h, 0.16, baseY + 0.06, 0.0)
    val rim = ArrayList<P3>()
    for (i in 0..48) {
        val a = i.toDouble() / 48 * PI * 2
        rim.add(proj(h, 0.16 + baseR * sin(a), baseY + 0.06, baseR * cos(a)))
    }
    val left = rim.reduce { m, q -> if (q.x < m.x) q else m }
    val right = rim.reduce { m, q -> if (q.x > m.x) q else m }
    val hh = h.ry * 1.6
    val apex = Pt2(c.x + sin(lean) * hh, c.y - cos(lean) * hh)
    val front = frontSilhouette(rim)

    val cone = Path2D()
    cone.moveTo(left.x, left.y)
    cone.quadraticCurveTo((left.x + apex.x) / 2 - h.rx * 0.06, (left.y + apex.y) / 2, apex.x - h.R * 0.05, apex.y + h.R * 0.06)
    cone.quadraticCurveTo(apex.x, apex.y - h.R * 0.03, apex.x + h.R * 0.05, apex.y + h.R * 0.06)
    cone.quadraticCurveTo((right.x + apex.x) / 2 + h.rx * 0.06, (right.y + apex.y) / 2, right.x, right.y)
    for (i in front.indices.reversed()) cone.lineTo(front[i].x, front[i].y)
    cone.closePath()
    ctx.fillStyle = ctx.lin(left.x, apex.y, right.x, left.y, listOf(0.0 to "#FF9BD0", 0.5 to "#F15BAE", 1.0 to "#C2187A"))
    ctx.fill(cone)

    ctx.save()
    ctx.clip(cone)
    if (!simple) {
        ctx.fillStyle("rgba(255,255,255,0.92)")
        val dots = listOf(
            0.25 to -0.35, 0.3 to 0.3, 0.55 to -0.05, 0.72 to 0.28, 0.8 to -0.3, 0.45 to 0.6, 0.48 to -0.65,
        )
        for ((t, u) in dots) {
            val bx = left.x + (right.x - left.x) * (0.5 + u * 0.5)
            val by = left.y + (right.y - left.y) * (0.5 + u * 0.5)
            val x = bx + (apex.x - bx) * (1 - t)
            val y = by + (apex.y - by) * (1 - t)
            val r = h.R * 0.075 * (0.6 + t * 0.5)
            ctx.beginPath()
            ctx.ellipse(x, y, r, r * 0.9, 0.0, 0.0, PI * 2)
            ctx.fill()
        }
    }
    ctx.fillStyle = ctx.lin(left.x, 0.0, right.x, 0.0, listOf(0.0 to "rgba(255,255,255,0.28)", 0.35 to "rgba(255,255,255,0)", 1.0 to "rgba(80,0,40,0.18)"))
    ctx.fill(cone)
    ctx.restore()

    if (front.size > 1) {
        ctx.polyline(front.pts())
        ctx.strokeStyle("#FFD84D")
        ctx.lineWidth = h.R * 0.07
        ctx.lineCap = Cap.ROUND
        ctx.stroke()
    }
    pompom(ctx, apex.x, apex.y - h.R * 0.04, h.R * 0.16, "#FFE27A", "#F2B705")
}

// ── Crown ─────────────────────────────────────────────────────────────────────

private const val CROWN_YB = 0.46

private class CrownSeg(val b: P3, val tt: P3, val z: Double)

/** side -1: the back half, behind the head; +1: the front half. */
internal fun crownPart(ctx: Ctx2D, h: Head, side: Int, simple: Boolean) {
    val s = 1.06
    val yb = CROWN_YB
    val yt = 0.66
    val n = 8
    val spikeH = 0.42
    val bigN = 120
    val seg = ArrayList<CrownSeg>()
    for (i in 0..bigN) {
        val lon = -PI + i.toDouble() / bigN * 2 * PI
        val b = proj(h, surf(yb, lon, s))
        val phase = (lon + PI) / (2 * PI) * n
        val f = phase - floor(phase)
        val spike = max(0.0, 1 - abs(f - 0.5) * 2).pow(1.6)
        val sp = surf(yt, lon, s)
        val tt = proj(h, sp.x * (1 - 0.08 * spike), yt + spikeH * spike, sp.z * (1 - 0.08 * spike))
        seg.add(CrownSeg(b, tt, b.z))
    }
    val keep = seg.filter { q -> if (side > 0) q.z >= 0 else q.z < 0.02 }.sortedBy { it.b.x }
    if (keep.size < 2) return
    val shape = Path2D()
    keep.forEachIndexed { i, q -> if (i > 0) shape.lineTo(q.tt.x, q.tt.y) else shape.moveTo(q.tt.x, q.tt.y) }
    for (i in keep.indices.reversed()) shape.lineTo(keep[i].b.x, keep[i].b.y)
    shape.closePath()

    val dark = side < 0
    ctx.fillStyle = ctx.lin(
        0.0, -h.ry * 1.05, 0.0, -h.ry * 0.45,
        if (dark) listOf(0.0 to "#C98A12", 1.0 to "#8A5A06") else listOf(0.0 to "#FFE58A", 0.5 to "#FBBF24", 1.0 to "#D08A0B"),
    )
    ctx.fill(shape)
    if (dark) return

    ctx.save()
    ctx.clip(shape)
    ctx.fillStyle = ctx.lin(
        -h.rx, 0.0, h.rx, 0.0,
        listOf(0.0 to "rgba(120,70,0,0.25)", 0.45 to "rgba(255,255,255,0)", 0.62 to "rgba(255,255,255,0.35)", 1.0 to "rgba(120,70,0,0.25)"),
    )
    ctx.fill(shape)
    ctx.restore()
    if (simple) return

    val gems = listOf("#EF4444", "#3B82F6", "#22C55E", "#A855F7")
    for (k in 0 until n) {
        val lon = -PI + (k + 0.5) / n * 2 * PI
        val sp = surf(yt, lon, s)
        val tipP = proj(h, sp.x * 0.92, yt + spikeH, sp.z * 0.92)
        val mid = proj(h, surf((yb + yt) / 2, lon, s * 1.01))
        if (mid.z <= 0.12) continue
        val r = h.R * 0.055
        ctx.beginPath()
        ctx.arc(tipP.x, tipP.y - r * 0.5, r, 0.0, PI * 2)
        ctx.fillStyle = ctx.rad(tipP.x - r * 0.3, tipP.y - r, 0.0, r * 1.2, listOf(0.0 to "#FFF6CC", 1.0 to "#E0A21A"))
        ctx.fill()
        val gr = h.R * 0.075
        ctx.beginPath()
        ctx.ellipse(mid.x, mid.y, gr * max(0.35, mid.z), gr, 0.0, 0.0, PI * 2)
        ctx.fillStyle(gems[k % gems.size])
        ctx.fill()
        ctx.beginPath()
        ctx.arc(mid.x - gr * 0.25 * mid.z, mid.y - gr * 0.35, gr * 0.28, 0.0, PI * 2)
        ctx.fillStyle("rgba(255,255,255,0.75)")
        ctx.fill()
    }
}

internal fun crownFront(ctx: Ctx2D, h: Head, body: Path2D, simple: Boolean) {
    // shadow of the band on the head
    ctx.save()
    ctx.clip(body)
    ctx.clip(capClip(h, CROWN_YB - 0.1, 1.0))
    ctx.clip(invert(capClip(h, CROWN_YB, 1.0), h), true)
    ctx.fillStyle("rgba(80,50,0,0.12)")
    ctx.fillAll(h)
    ctx.restore()
    crownPart(ctx, h, 1, simple)
}

// ── Witch hat ─────────────────────────────────────────────────────────────────

internal fun witchBrim(h: Head): List<P3> {
    val y = 0.7
    val rr = 1.42
    val pts = ArrayList<P3>()
    for (i in 0..120) {
        val a = -PI + i.toDouble() / 120 * 2 * PI
        val wob = 1 + 0.035 * sin(a * 3 + 0.6)
        val droop = -0.1 * abs(sin(a)).pow(2) // the edges droop a little
        pts.add(proj(h, rr * wob * sin(a), y + droop, rr * wob * cos(a)))
    }
    return pts
}

internal fun closedPath(pts: List<Pt2>): Path2D {
    val p = Path2D()
    pts.forEachIndexed { i, q -> if (i > 0) p.lineTo(q.x, q.y) else p.moveTo(q.x, q.y) }
    p.closePath()
    return p
}

/** The whole brim, behind the head; the front draws its front half again. */
internal fun witchHatBack(ctx: Ctx2D, h: Head) {
    ctx.fillStyle = ctx.lin(0.0, -h.ry, 0.0, -h.ry * 0.4, listOf(0.0 to "#2A0A4F", 1.0 to "#3B0F6B"))
    ctx.fill(closedPath(witchBrim(h).pts()))
}

internal fun witchHatFront(ctx: Ctx2D, h: Head, body: Path2D) {
    val all = witchBrim(h)
    val brim = closedPath(all.pts())
    val fr = all.filter { it.z >= 0 }.sortedBy { it.x }

    ctx.save()
    ctx.clip(body)
    ctx.clip(capClip(h, 0.5, 1.0))
    ctx.fillStyle("rgba(40,0,70,0.10)")
    ctx.fillAll(h)
    ctx.restore()

    ctx.fillStyle = ctx.lin(0.0, -h.ry * 0.9, 0.0, -h.ry * 0.3, listOf(0.0 to "#5B21B6", 1.0 to "#3B0764"))
    ctx.fill(brim)
    if (fr.size > 1) {
        ctx.polyline(fr.pts())
        ctx.strokeStyle("rgba(190,150,255,0.35)")
        ctx.lineWidth = h.R * 0.035
        ctx.lineCap = Cap.ROUND
        ctx.stroke()
    }

    // cone: base ring r = 0.62 at y = 0.74, tall apex, the tip bends over
    val baseR = 0.62
    val by = 0.74
    val bl = proj(h, -baseR, by, 0.0)
    val br = proj(h, baseR, by, 0.0)
    val c = proj(h, 0.0, by, 0.0)
    val lean = 0.1 + h.physDx * 0.15
    val top = Pt2(c.x + h.rx * 0.18 + sin(lean) * h.ry * 0.3, c.y - h.ry * 1.25)
    val tip = Pt2(top.x + h.rx * (0.45 + h.physDx * 0.25), top.y + h.ry * (0.22 + h.physDy * 0.1))
    val capFront = frontArc(h, by, baseR / ringR(by)).filter { it.x >= bl.x - 1 && it.x <= br.x + 1 }
    val cone = Path2D()
    cone.moveTo(bl.x, bl.y)
    cone.bezierCurveTo(bl.x + h.rx * 0.12, bl.y - h.ry * 0.5, top.x - h.rx * 0.28, top.y + h.ry * 0.25, top.x - h.rx * 0.02, top.y - h.ry * 0.02)
    cone.quadraticCurveTo(top.x + h.rx * 0.25, top.y - h.ry * 0.08, tip.x, tip.y)
    cone.quadraticCurveTo(top.x + h.rx * 0.22, top.y + h.ry * 0.08, top.x + h.rx * 0.14, top.y + h.ry * 0.22)
    cone.bezierCurveTo(br.x - h.rx * 0.18, c.y - h.ry * 0.45, br.x - h.rx * 0.02, br.y - h.ry * 0.2, br.x, br.y)
    for (i in capFront.indices.reversed()) cone.lineTo(capFront[i].x, capFront[i].y)
    cone.closePath()
    ctx.fillStyle = ctx.lin(bl.x, top.y, br.x, bl.y, listOf(0.0 to "#7C3AED", 0.55 to "#4C1D95", 1.0 to "#2E1065"))
    ctx.fill(cone)

    ctx.save()
    ctx.clip(cone)
    ctx.fillStyle = ctx.lin(bl.x, 0.0, br.x, 0.0, listOf(0.0 to "rgba(255,255,255,0.22)", 0.4 to "rgba(255,255,255,0)", 1.0 to "rgba(0,0,0,0.15)"))
    ctx.fill(cone)
    // crease where the tip bends
    ctx.beginPath()
    ctx.moveTo(top.x - h.rx * 0.05, top.y + h.ry * 0.05)
    ctx.quadraticCurveTo(top.x + h.rx * 0.1, top.y + h.ry * 0.12, top.x + h.rx * 0.2, top.y + h.ry * 0.06)
    ctx.strokeStyle("rgba(20,0,40,0.35)")
    ctx.lineWidth = h.R * 0.05
    ctx.lineCap = Cap.ROUND
    ctx.stroke()
    // orange band, just above the base
    val fc = proj(h, 0.0, by, baseR)
    val lift = h.ry * 0.11
    ctx.beginPath()
    ctx.moveTo(bl.x - 2, bl.y - lift)
    ctx.quadraticCurveTo(fc.x, 2 * (fc.y - lift) - (bl.y + br.y) / 2, br.x + 2, br.y - lift)
    ctx.strokeStyle("#F97316")
    ctx.lineWidth = h.ry * 0.17
    ctx.lineCap = Cap.BUTT
    ctx.stroke()
    ctx.restore()

    // buckle
    val bw = h.R * 0.2
    val bh = h.R * 0.16
    ctx.save()
    ctx.translate(fc.x, fc.y - h.ry * 0.11)
    ctx.roundRect(-bw / 2, -bh / 2, bw, bh, bh * 0.25)
    ctx.fillStyle("#FCD34D")
    ctx.fill()
    ctx.roundRect(-bw / 2 + bw * 0.24, -bh / 2 + bh * 0.28, bw * 0.52, bh * 0.44, bh * 0.1)
    ctx.fillStyle("#C2410C")
    ctx.fill()
    ctx.restore()
}

// ── Glasses (pinned to the real eye positions) ────────────────────────────────
