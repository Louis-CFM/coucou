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

/** Which outfit is drawn behind and in front of Mochi. The drawing of each is in OutfitHats.kt and OutfitWear.kt, the shared helpers in OutfitDrawing.kt. */

private fun faceTurnedAway(h: Head) = proj(h, 0.0, 0.0, 1.0).z < 0

private fun drawFace(ctx: Ctx2D, outfit: Outfit, h: Head, body: Path2D, simple: Boolean) {
    when (outfit) {
        Outfit.SUNGLASSES -> sunglasses(ctx, h, body)
        Outfit.ROUND_GLASSES -> roundGlasses(ctx, h, body)
        Outfit.SCARF -> scarf(ctx, h)
        Outfit.PUMPKIN -> pumpkin(ctx, h, body, simple)
        Outfit.BOW -> bow(ctx, h)
        else -> {}
    }
}

fun layerAlpha(st: OutfitState): Double {
    val morphFade = 1 - min(1.0, max(0.0, (st.morph - 0.3) / 0.2))
    return morphFade * min(1.0, st.presence * 2.5)
}

/** The parts behind Mochi's body. [ctx] is in body space (translated to the body centre, tilted and squashed like the body). */
fun drawOutfitBehind(ctx: Ctx2D, outfit: Outfit, h: Head, st: OutfitState) {
    if (outfit == Outfit.NONE) return
    val alpha = layerAlpha(st)
    if (alpha <= 0.005) return
    val simple = h.R < SIMPLIFY_BELOW_R
    val body = bodyOutline(h.rx, h.ry)

    if (outfit in ON_FACE) {
        if (faceTurnedAway(h)) ctx.withLayer(alpha) { l -> drawFace(l, outfit, h, body, simple) }
        return
    }
    val posP = Ease.back(st.presence)
    val hatScale = 0.85 + 0.15 * posP
    ctx.save()
    ctx.translate(0.0, -(1 - posP) * h.ry)
    ctx.scale(hatScale, hatScale)
    ctx.withLayer(alpha) { l ->
        when (outfit) {
            Outfit.BUNNY_EARS -> bunnyEars(l, h)
            Outfit.CROWN -> crownPart(l, h, -1, simple)
            Outfit.WITCH_HAT -> witchHatBack(l, h)
            else -> {}
        }
    }
    ctx.restore()
}

/** The parts in front of Mochi, drawn after the body and the eyes. */
fun drawOutfitFront(ctx: Ctx2D, outfit: Outfit, h: Head, st: OutfitState) {
    if (outfit == Outfit.NONE || outfit == Outfit.BUNNY_EARS) return
    if (outfit in ON_FACE && faceTurnedAway(h)) return
    val alpha = layerAlpha(st)
    if (alpha <= 0.005) return
    val simple = h.R < SIMPLIFY_BELOW_R
    val body = bodyOutline(h.rx, h.ry)
    val p = st.presence
    val posP = Ease.back(p)

    ctx.save()
    if (outfit in HATS) {
        // hats drop onto the head and settle
        val hatScale = 0.85 + 0.15 * posP
        ctx.translate(0.0, -(1 - posP) * h.ry)
        ctx.scale(hatScale, hatScale)
    } else if (outfit == Outfit.SUNGLASSES || outfit == Outfit.ROUND_GLASSES) {
        ctx.translate(0.0, (1 - p) * 0.25 * h.ry)
    } else if (outfit == Outfit.SCARF) {
        ctx.translate(0.0, (1 - p) * 0.3 * h.ry)
    } else if (outfit == Outfit.BOW) {
        ctx.scale(max(0.001, posP), max(0.001, posP))
    }
    ctx.withLayer(alpha) { l ->
        when (outfit) {
            Outfit.BEANIE -> beanie(l, h, body, simple)
            Outfit.SANTA_HAT -> santaHat(l, h, body)
            Outfit.PARTY_HAT -> partyHat(l, h, simple)
            Outfit.CROWN -> crownFront(l, h, body, simple)
            Outfit.WITCH_HAT -> witchHatFront(l, h, body)
            else -> drawFace(l, outfit, h, body, simple)
        }
    }
    ctx.restore()
}

// ── Wardrobe icons ────────────────────────────────────────────────────────────

private const val INK = "rgb(26,20,18)"

/** A little Mochi wearing [outfit], centred in a [size] x [size] icon (the PC's iconMochi). */
fun drawIconMochi(ctx: Ctx2D, size: Double, outfit: Outfit) {
    val r = 10.0
    val h = makeHead(r)
    val cx = size / 2
    val cy = size / 2 + r * 0.62
    val st = OutfitState(1.0, 0.0)
    ctx.save()
    ctx.translate(cx, cy)
    drawOutfitBehind(ctx, outfit, h, st)
    val body = bodyOutline(h.rx, h.ry)
    val (top, bottom) = if (outfit == Outfit.PUMPKIN) PUMPKIN_BODY else ("rgb(237,237,239)" to "rgb(196,197,202)")
    ctx.fillStyle = ctx.lin(h.rx * 0.7, -h.ry * 0.85, -h.rx * 0.8, h.ry * 0.9, listOf(0.0 to top, 1.0 to bottom))
    ctx.fill(body)
    ctx.fillStyle = ctx.rad(0.0, 0.0, r * 0.15, r * 1.25, listOf(0.0 to "rgba(0,0,0,0)", 0.6 to "rgba(0,0,0,0)", 1.0 to "rgba(0,0,0,0.2)"))
    ctx.fill(body)
    ctx.fillStyle = ctx.rad(h.rx * 0.34, -h.ry * 0.46, 0.0, r * 0.42, listOf(0.0 to "rgba(255,255,255,0.55)", 1.0 to "rgba(255,255,255,0)"))
    ctx.fill(body)
    ctx.save()
    ctx.clip(body)
    ctx.fillStyle(INK)
    for (e in eyeFrames(h)) {
        if (!e.visible) continue
        ctx.save()
        ctx.translate(e.x, e.y)
        ctx.scale(e.fx, e.fy)
        val hh = max(e.h, e.w * 0.3)
        ctx.roundRect(-e.w / 2, -hh / 2, e.w, hh, min(e.w / 2, hh / 2))
        ctx.fill()
        ctx.restore()
    }
    ctx.restore()
    drawOutfitFront(ctx, outfit, h, st)
    ctx.restore()
}
