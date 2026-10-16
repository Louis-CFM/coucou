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

// Glasses, scarf, pumpkin, bow, bunny ears: parts of the port in Outfits.kt.

internal fun sunglasses(ctx: Ctx2D, h: Head, body: Path2D) {
    val eyes = eyeFrames(h)
    val w = h.R * 0.62
    val hh = h.R * 0.46
    ctx.save()
    ctx.clip(body)
    ctx.strokeStyle("#111317")
    ctx.lineCap = Cap.ROUND
    val l = eyes[0]
    val r = eyes[1]
    if (l.visible && r.visible) {
        ctx.beginPath()
        ctx.moveTo(l.x + (w / 2) * l.fx * 0.9, l.y - hh * 0.18)
        ctx.quadraticCurveTo((l.x + r.x) / 2, (l.y + r.y) / 2 - hh * 0.42, r.x - (w / 2) * r.fx * 0.9, r.y - hh * 0.18)
        ctx.lineWidth = h.R * 0.07
        ctx.stroke()
    }
    ctx.lineWidth = h.R * 0.06
    for (e in eyes) {
        if (!e.visible) continue
        ctx.beginPath()
        ctx.moveTo(e.x + (e.sd * w) / 2 * e.fx, e.y - hh * 0.2)
        ctx.lineTo(e.sd * h.rx * 1.05, e.y - hh * 0.35)
        ctx.stroke()
    }
    for (e in eyes) {
        if (!e.visible) continue
        ctx.save()
        ctx.translate(e.x, e.y)
        ctx.scale(e.fx, e.fy)
        ctx.roundRect(-w / 2, -hh / 2, w, hh, hh * 0.42)
        ctx.fillStyle("rgba(17,19,23,0.82)")
        ctx.fill()
        ctx.lineWidth = h.R * 0.05
        ctx.strokeStyle("#0B0C0F")
        ctx.stroke()
        ctx.beginPath()
        ctx.moveTo(-w * 0.28, -hh * 0.05)
        ctx.lineTo(-w * 0.05, -hh * 0.3)
        ctx.strokeStyle("rgba(255,255,255,0.45)")
        ctx.stroke()
        ctx.restore()
    }
    ctx.restore()
}

internal fun roundGlasses(ctx: Ctx2D, h: Head, body: Path2D) {
    val eyes = eyeFrames(h)
    val d = h.R * 0.56
    ctx.save()
    ctx.clip(body)
    ctx.strokeStyle("#8A4B12")
    ctx.lineCap = Cap.ROUND
    val l = eyes[0]
    val r = eyes[1]
    if (l.visible && r.visible) {
        ctx.beginPath()
        ctx.moveTo(l.x + (d / 2) * l.fx, l.y - d * 0.08)
        ctx.quadraticCurveTo((l.x + r.x) / 2, (l.y + r.y) / 2 - d * 0.3, r.x - (d / 2) * r.fx, r.y - d * 0.08)
        ctx.lineWidth = h.R * 0.055
        ctx.stroke()
    }
    ctx.lineWidth = h.R * 0.05
    for (e in eyes) {
        if (!e.visible) continue
        ctx.beginPath()
        ctx.moveTo(e.x + (e.sd * d) / 2 * e.fx, e.y - d * 0.1)
        ctx.lineTo(e.sd * h.rx * 1.05, e.y - d * 0.25)
        ctx.stroke()
    }
    for (e in eyes) {
        if (!e.visible) continue
        ctx.save()
        ctx.translate(e.x, e.y)
        ctx.scale(e.fx, e.fy)
        ctx.beginPath()
        ctx.arc(0.0, 0.0, d / 2, 0.0, PI * 2)
        ctx.fillStyle("rgba(190,225,255,0.18)")
        ctx.fill()
        ctx.lineWidth = h.R * 0.065
        ctx.strokeStyle("#9A5A1A")
        ctx.stroke()
        ctx.beginPath()
        ctx.arc(0.0, 0.0, d / 2 - h.R * 0.03, PI * 1.1, PI * 1.45)
        ctx.strokeStyle("rgba(255,255,255,0.55)")
        ctx.lineWidth = h.R * 0.03
        ctx.stroke()
        ctx.restore()
    }
    ctx.restore()
}

// ── Scarf ─────────────────────────────────────────────────────────────────────

internal fun scarf(ctx: Ctx2D, h: Head) {
    val s = 1.05
    val y0 = -0.34
    val y1 = -0.66
    val top = frontArc(h, y0, s)
    val bot = frontArc(h, y1, s)
    if (top.isEmpty() || bot.isEmpty()) return
    val band = Path2D()
    top.forEachIndexed { i, q -> if (i > 0) band.lineTo(q.x, q.y) else band.moveTo(q.x, q.y) }
    for (i in bot.indices.reversed()) band.lineTo(bot[i].x, bot[i].y)
    band.closePath()

    ctx.save()
    ctx.clip(bodyOutline(h.rx * s, h.ry * s))
    ctx.fillStyle = ctx.lin(0.0, -h.ry * 0.2, 0.0, h.ry * 0.7, listOf(0.0 to "#F87171", 1.0 to "#B91C1C"))
    ctx.fill(band)
    ctx.save()
    ctx.clip(band)
    ctx.strokeStyle("rgba(255,255,255,0.85)")
    ctx.lineCap = Cap.ROUND
    for (lon in listOf(-1.0, -0.45, 0.1, 0.65, 1.2)) {
        val a = proj(h, surf(y0, lon, s))
        val b = proj(h, surf(y1, lon, s))
        if (a.z < 0) continue
        ctx.beginPath()
        ctx.moveTo(a.x, a.y - 4)
        ctx.lineTo(b.x, b.y + 4)
        ctx.lineWidth = h.R * 0.09 * max(0.3, a.z)
        ctx.stroke()
    }
    ctx.restore()
    ctx.fillStyle = ctx.lin(0.0, -h.ry * 0.5, 0.0, h.ry * 0.3, listOf(0.0 to "rgba(255,255,255,0.18)", 1.0 to "rgba(0,0,0,0.1)"))
    ctx.fill(band)
    ctx.restore()

    // the hanging end, from the knot
    val k = proj(h, surf((y0 + y1) / 2, -0.55, s * 1.03))
    if (k.z <= 0) return
    val sw = h.physDx * h.rx * 0.12
    val end = Path2D()
    end.moveTo(k.x - h.R * 0.16, k.y)
    end.quadraticCurveTo(k.x - h.R * 0.24 + sw, k.y + h.ry * 0.35, k.x - h.R * 0.2 + sw * 1.4, k.y + h.ry * 0.62)
    end.lineTo(k.x + h.R * 0.06 + sw * 1.4, k.y + h.ry * 0.6)
    end.quadraticCurveTo(k.x + h.R * 0.02 + sw, k.y + h.ry * 0.3, k.x + h.R * 0.12, k.y)
    end.closePath()
    ctx.fillStyle = ctx.lin(0.0, k.y, 0.0, k.y + h.ry * 0.6, listOf(0.0 to "#EF4444", 1.0 to "#B91C1C"))
    ctx.fill(end)
    ctx.save()
    ctx.clip(end)
    ctx.fillStyle("rgba(255,255,255,0.85)")
    for (t in listOf(0.35, 0.7)) ctx.fillRect(k.x - h.R * 0.4 + sw, k.y + h.ry * 0.62 * t, h.R * 0.8, h.R * 0.07)
    ctx.restore()
    // fringe
    ctx.strokeStyle("#DC2626")
    ctx.lineWidth = h.R * 0.035
    ctx.lineCap = Cap.ROUND
    for (i in 0 until 4) {
        val fx = k.x - h.R * 0.17 + sw * 1.4 + i * h.R * 0.075
        ctx.beginPath()
        ctx.moveTo(fx, k.y + h.ry * 0.6)
        ctx.lineTo(fx, k.y + h.ry * 0.72)
        ctx.stroke()
    }
    // knot
    ctx.beginPath()
    ctx.ellipse(k.x, k.y, h.R * 0.17, h.R * 0.14, 0.2, 0.0, PI * 2)
    ctx.fillStyle = ctx.rad(k.x - h.R * 0.05, k.y - h.R * 0.05, 0.0, h.R * 0.2, listOf(0.0 to "#F87171", 1.0 to "#B91C1C"))
    ctx.fill()
}

// ── Pumpkin (the body colours come from the engine) ───────────────────────────

val PUMPKIN_BODY: Pair<String, String> = "#FFA94D" to "#E8590C"

internal fun pumpkin(ctx: Ctx2D, h: Head, body: Path2D, simple: Boolean) {
    if (!simple) {
        ctx.save()
        ctx.clip(body)
        ctx.lineCap = Cap.ROUND
        for (lon in listOf(-1.15, -0.55, 0.0, 0.55, 1.15)) {
            val pts = ArrayList<P3>()
            for (i in 0..30) {
                val q = proj(h, surf(-0.98 + 1.96 * i / 30, lon, 1.0))
                if (q.z > 0) pts.add(q)
            }
            if (pts.size < 2) continue
            val zz = pts[floor(pts.size / 2.0).toInt()].z
            ctx.polyline(pts.pts())
            ctx.strokeStyle("rgba(150,50,0,${0.22 * zz})")
            ctx.lineWidth = h.R * 0.12
            ctx.stroke()
            ctx.polyline(pts.map { Pt2(it.x + h.R * 0.07, it.y) })
            ctx.strokeStyle("rgba(255,220,170,${0.18 * zz})")
            ctx.lineWidth = h.R * 0.04
            ctx.stroke()
        }
        ctx.restore()
    }
    val t = proj(h, 0.02, 1.0, 0.0)
    // stem
    ctx.beginPath()
    ctx.moveTo(t.x - h.R * 0.09, t.y + h.R * 0.04)
    ctx.quadraticCurveTo(t.x - h.R * 0.08, t.y - h.R * 0.22, t.x + h.R * 0.08, t.y - h.R * 0.3)
    ctx.lineTo(t.x + h.R * 0.13, t.y - h.R * 0.22)
    ctx.quadraticCurveTo(t.x + h.R * 0.04, t.y - h.R * 0.15, t.x + h.R * 0.08, t.y + h.R * 0.04)
    ctx.closePath()
    ctx.fillStyle = ctx.lin(t.x - h.R * 0.1, 0.0, t.x + h.R * 0.1, 0.0, listOf(0.0 to "#65A30D", 1.0 to "#3F6212"))
    ctx.fill()
    // leaf
    ctx.save()
    ctx.translate(t.x - h.R * 0.06, t.y - h.R * 0.02)
    ctx.rotate(-0.5)
    ctx.beginPath()
    ctx.moveTo(0.0, 0.0)
    ctx.quadraticCurveTo(-h.R * 0.18, -h.R * 0.2, -h.R * 0.38, -h.R * 0.02)
    ctx.quadraticCurveTo(-h.R * 0.18, h.R * 0.1, 0.0, 0.0)
    ctx.fillStyle = ctx.lin(0.0, -h.R * 0.15, -h.R * 0.3, 0.0, listOf(0.0 to "#84CC16", 1.0 to "#4D7C0F"))
    ctx.fill()
    ctx.beginPath()
    ctx.moveTo(-h.R * 0.02, -h.R * 0.01)
    ctx.quadraticCurveTo(-h.R * 0.18, -h.R * 0.08, -h.R * 0.32, -h.R * 0.03)
    ctx.strokeStyle("rgba(30,60,0,0.4)")
    ctx.lineWidth = h.R * 0.02
    ctx.lineCap = Cap.ROUND
    ctx.stroke()
    ctx.restore()
    if (simple) return
    // curly tendril
    ctx.beginPath()
    ctx.moveTo(t.x + h.R * 0.1, t.y - h.R * 0.12)
    ctx.bezierCurveTo(t.x + h.R * 0.3, t.y - h.R * 0.25, t.x + h.R * 0.35, t.y - h.R * 0.02, t.x + h.R * 0.22, t.y - h.R * 0.06)
    ctx.strokeStyle("#4D7C0F")
    ctx.lineWidth = h.R * 0.03
    ctx.lineCap = Cap.ROUND
    ctx.stroke()
}

// ── Bow (anchored in 3D, turns with the head) ─────────────────────────────────

internal fun bow(ctx: Ctx2D, h: Head) {
    val a = proj(h, surf(0.86, 0.55, 1.02))
    if (a.z < -0.2) return
    val s = h.R * 0.26
    val sq = max(0.45, cos(0.55 + h.yaw))
    ctx.save()
    ctx.translate(a.x, a.y)
    ctx.rotate(0.35 + h.yaw * 0.3)
    ctx.scale(sq, 1.0)
    for (sd in listOf(-1.0, 1.0)) {
        ctx.beginPath()
        ctx.moveTo(0.0, 0.0)
        ctx.bezierCurveTo(sd * s * 0.6, -s * 0.85, sd * s * 1.35, -s * 0.55, sd * s * 1.15, 0.0)
        ctx.bezierCurveTo(sd * s * 1.35, s * 0.55, sd * s * 0.6, s * 0.85, 0.0, 0.0)
        ctx.fillStyle = ctx.lin(0.0, -s, 0.0, s, listOf(0.0 to "#FF8CC6", 1.0 to "#DB2777"))
        ctx.fill()
        ctx.beginPath()
        ctx.moveTo(sd * s * 0.25, -s * 0.05)
        ctx.quadraticCurveTo(sd * s * 0.7, -s * 0.15, sd * s * 0.95, -s * 0.05)
        ctx.strokeStyle("rgba(140,10,70,0.35)")
        ctx.lineWidth = s * 0.08
        ctx.lineCap = Cap.ROUND
        ctx.stroke()
    }
    ctx.beginPath()
    ctx.ellipse(0.0, 0.0, s * 0.24, s * 0.3, 0.0, 0.0, PI * 2)
    ctx.fillStyle = ctx.rad(-s * 0.06, -s * 0.1, 0.0, s * 0.35, listOf(0.0 to "#FFB3D9", 1.0 to "#C2185B"))
    ctx.fill()
    ctx.restore()
}

// ── Bunny ears (always behind the head) ───────────────────────────────────────

internal fun bunnyEars(ctx: Ctx2D, h: Head) {
    val r = h.R
    val earH = r * 0.85
    for (sd in listOf(-1.0, 1.0)) {
        val root = proj(h, sd * 0.45, 0.92, 0.0)
        val rootL = proj(h, sd * 0.45 - 0.22, 0.92, 0.0)
        val rootR = proj(h, sd * 0.45 + 0.22, 0.92, 0.0)
        val hw = max(r * 0.04, abs(rootR.x - rootL.x) / 2)
        ctx.save()
        ctx.translate(root.x, root.y - earH * 0.15)
        ctx.beginPath()
        ctx.ellipse(0.0, 0.0, hw, earH / 2, 0.0, 0.0, PI * 2)
        ctx.fillStyle("#F9F0F0")
        ctx.fill()
        ctx.strokeStyle("rgba(0,0,0,0.06)")
        ctx.lineWidth = 0.8
        ctx.stroke()
        ctx.beginPath()
        ctx.ellipse(0.0, -earH / 2 + r * 0.1 + earH * 0.325, hw * 0.5, earH * 0.325, 0.0, 0.0, PI * 2)
        ctx.fillStyle("rgba(252,165,165,0.7)")
        ctx.fill()
        ctx.restore()
    }
}

// ── Layers and transitions ────────────────────────────────────────────────────

/** What Mochi can wear. The raw values are the Mac's and the PC's (stored in the preferences), keep them stable. */
enum class Outfit(val id: String) {
    NONE("none"), PARTY_HAT("partyHat"), BEANIE("beanie"), CROWN("crown"), SUNGLASSES("sunglasses"),
    ROUND_GLASSES("roundGlasses"), BOW("bow"), SCARF("scarf"), WITCH_HAT("witchHat"), PUMPKIN("pumpkin"),
    SANTA_HAT("santaHat"), BUNNY_EARS("bunnyEars");
}

/** Glasses, bow, scarf and pumpkin are on the face: behind the head once it has turned away. */
internal val ON_FACE = setOf(Outfit.SUNGLASSES, Outfit.ROUND_GLASSES, Outfit.BOW, Outfit.SCARF, Outfit.PUMPKIN)
internal val HATS = setOf(Outfit.BEANIE, Outfit.SANTA_HAT, Outfit.PARTY_HAT, Outfit.CROWN, Outfit.WITCH_HAT)

/** [presence] 0 = gone, 1 = fully on (animated by the engine); [morph] is Mochi's mailbox morph: outfits fade as he turns into a box. */
data class OutfitState(val presence: Double, val morph: Double)
