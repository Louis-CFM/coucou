package fr.louisraille.coucou.phone

import android.provider.Settings
import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.layout.onVisibilityChanged
import androidx.compose.ui.platform.LocalContext
import kotlinx.coroutines.isActive
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin

/**
 * The phone's Mochi — a faithful port of the mini bot CoucouKit draws on the
 * iPhone (BotEngine with isMini=true): a white superellipse body, sphere-mapped
 * eyes, per-state eye shape and a corner badge. He blinks, drifts his gaze in
 * the same poses as iOS MochiPose.idle, bobs while waiting and his badge
 * pulses. Animation stops off-screen and honours "Remove animations".
 */
object MochiSpec {
    const val EYE_W = 0.25f
    const val EYE_H = 0.27f
    const val EYE_SP = 0.37f
    const val EYE_P = -0.12f
    const val EYE_MULT = 1.9f          // isMini
    val Ink = Color(0xFF10131A)

    enum class State(val eye: Eye, val badge: Badge?, val tint: Color, val bob: Boolean = false) {
        Idle(Eye.Pill, null, Color(0xFFE6E9EE)),
        Working(Eye.Pill, Badge.Dots, Coucou.Working),
        Thinking(Eye.Pill, Badge.Dots, Coucou.Thinking),
        Searching(Eye.Pill, Badge.Dots, Color(0xFF6365F2)),
        Approval(Eye.Wide, Badge.Bang, Coucou.Approval, bob = true),
        Question(Eye.Pill, Badge.Question, Coucou.Question),
        Error(Eye.Flat, Badge.Dot, Coucou.Error),
        Finished(Eye.Happy, Badge.Dot, Coucou.Done),
        RateLimit(Eye.Tired, Badge.Dot, Coucou.RateLimit),
        Sleeping(Eye.Closed, null, Coucou.Sleeping),
        Dizzy(Eye.Spiral, null, Color(0xFFF472B6)),
        ;

        companion object {
            fun of(name: String) = entries.firstOrNull { it.name.equals(name, true) } ?: Idle
        }
    }

    enum class Eye { Pill, Wide, Flat, Happy, Closed, Tired, Spiral }
    enum class Badge { Dots, Bang, Question, Dot }

    /** Tile behind a white Mochi — iOS mochiTile(): light agents get a grey tile. */
    fun tile(color: Color): Color =
        if (color.luminance() > 0.7f) Color(0xFF525252) else color
}

private data class Pose(val yaw: Float = 0f, val pitch: Float = 0f, val tilt: Float = 0f)

// The same little wander as iOS MochiPose.idlePoses (minus the eye overrides —
// blink handles that here).
private val IDLE_POSES = listOf(
    Pose(),
    Pose(yaw = -0.45f),
    Pose(yaw = 0.45f),
    Pose(yaw = -0.3f, pitch = -0.25f),
    Pose(yaw = 0.35f, pitch = 0.2f, tilt = 0.08f),
    Pose(pitch = -0.3f, tilt = -0.06f),
    Pose(yaw = -0.5f, tilt = -0.1f),
    Pose(yaw = 0.15f, pitch = 0.25f),
)

private fun hashOf(id: String): Long {
    var hash = 5381L
    for (b in id.toByteArray()) hash = (hash * 33 + b) and 0x7fffffffffffffffL
    return hash xor (hash ushr 13)
}

@Composable
fun Mochi(
    state: MochiSpec.State,
    modifier: Modifier = Modifier,
    bodyColor: Color = Color.White,
    seed: String = "",
) {
    val ctx = LocalContext.current
    // "Remove animations" — animator scale 0 means draw one still frame.
    val animate = remember {
        Settings.Global.getFloat(ctx.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) > 0f
    }
    var visible by remember { mutableStateOf(true) }
    var time by remember { mutableFloatStateOf(0f) }

    if (animate) {
        LaunchedEffect(visible) {
            val start = System.nanoTime()
            var last = 0L
            while (isActive) {
                withFrameNanos { now ->
                    // ~30 fps is plenty for a tile; also cheap on 120 Hz screens.
                    if (visible && now - last >= 33_000_000L) {
                        last = now
                        time = (now - start) / 1e9f
                    }
                }
            }
        }
    }

    Canvas(modifier.onVisibilityChanged { visible = it }) {
        drawMochi(state, bodyColor, time, seed)
    }
}

// MARK: - drawing (port of BotEngine.draw with isMini=true)

private fun DrawScope.drawMochi(state: MochiSpec.State, bodyColor: Color, t: Float, seed: String) {
    val W = size.width
    val H = size.height
    val R = W * 0.3f
    val rx = R * 1.14f
    val ry = R * 0.88f

    // Idle drift: the same pose a widget would pick, re-picked every ~4 s,
    // smoothed by a sine so it eases rather than snaps.
    val h = hashOf(seed)
    val tick = (t / 4f).toInt()
    val pose = if (state == MochiSpec.State.Idle || state == MochiSpec.State.Sleeping) {
        val p = poseForTick(h, tick)
        Pose(p.yaw * 0.6f, p.pitch * 0.6f, p.tilt * 0.6f)
    } else if (state == MochiSpec.State.Thinking) Pose(yaw = 0.4f, pitch = -0.3f)
    else if (state == MochiSpec.State.Question) Pose(tilt = 0.17f)
    else Pose()

    // Blink: every ~3.8 s, a 140 ms closed window; offset per Mochi so a list
    // of them doesn't blink in lockstep. Waiting states never blink.
    val blinkOffset = (h % 4000) / 1000f
    val blinkPhase = if (state.bob || state.eye == MochiSpec.Eye.Closed) 1f
    else ((t + blinkOffset) % 3.8f).let { if (it > 3.66f) 0.1f else 1f }

    // Approval bob + sleeping breathe.
    val bob = if (state.bob) sin(t * 5.2f) * 0.05f else 0f
    val breathe = if (state == MochiSpec.State.Sleeping) 1f + 0.03f * sin(t * 1.6f) else 1f

    val cx = W / 2f
    val cy = H / 2f + R * 0.06f + bob * R

    withTransform({
        translate(cx, cy)
        if (pose.tilt != 0f) rotate(Math.toDegrees(pose.tilt.toDouble()).toFloat())
        scale(1f, breathe)
    }) {
        // Body — superellipse n=2.7, flat fill (the mini look).
        val body = superellipse(rx, ry)
        drawPath(body, bodyColor)

        clipPath(body) {
            drawEyes(state, blinkPhase, pose, R, rx, ry, t)
        }
    }

    // Badge — top-left corner, scale 1.25 like the mini bot.
    state.badge?.let { badge ->
        val bx = cx - R * 0.72f
        val by = cy - R * 0.72f
        translate(bx, by) {
            scale(1.25f) {
                drawBadge(badge, state.tint, R, t)
            }
        }
    }
}

private fun poseForTick(h: Long, tick: Int): Pose {
    val mixed = (h * 31 + tick * 7919L).let { it xor (it ushr 13) }
    val n = IDLE_POSES.size
    return IDLE_POSES[(((mixed % n) + n) % n).toInt()]
}

private fun superellipse(rx: Float, ry: Float): Path {
    val n = 72
    val e = 2.0f / 2.7f
    val p = Path()
    for (i in 0..n) {
        val a = i.toFloat() / n * 2f * PI.toFloat()
        val ca = cos(a)
        val sa = sin(a)
        val x = rx * (if (ca >= 0) ca.pow(e) else -(-ca).pow(e))
        val y = ry * (if (sa >= 0) sa.pow(e) else -(-sa).pow(e))
        if (i == 0) p.moveTo(x, y) else p.lineTo(x, y)
    }
    p.close()
    return p
}

private fun DrawScope.drawEyes(
    state: MochiSpec.State, open: Float, pose: Pose, R: Float, rx: Float, ry: Float, t: Float,
) {
    for (sd in listOf(-1f, 1f)) {
        val eyeYaw = sd * MochiSpec.EYE_SP + pose.yaw
        val eyePitch = MochiSpec.EYE_P + pose.pitch
        val cp = cos(eyePitch)
        if (cos(eyeYaw) * cp <= 0.04f) continue

        val ex = sin(eyeYaw) * cp * rx
        val ey = -sin(eyePitch) * ry
        val fx = max(0.18f, cos(eyeYaw))
        val fy = max(0.18f, cp)

        var w = R * MochiSpec.EYE_W * MochiSpec.EYE_MULT
        var hh = R * MochiSpec.EYE_H * MochiSpec.EYE_MULT
        if (state.eye == MochiSpec.Eye.Wide) { w *= 1.16f; hh *= 1.12f }

        withTransform({
            translate(ex, ey)
            scale(fx, fy)
        }) {
            drawEye(state.eye, w, hh, open, sd, R, t)
        }
    }
}

private fun DrawScope.drawEye(
    eye: MochiSpec.Eye, w: Float, h: Float, open: Float, sd: Float, R: Float, t: Float,
) {
    val ink = MochiSpec.Ink
    when (eye) {
        MochiSpec.Eye.Pill, MochiSpec.Eye.Wide -> {
            val hh = max(h * open, w * 0.3f)
            drawRoundRect(ink, Offset(-w / 2, -hh / 2), Size(w, hh),
                cornerRadius = androidx.compose.ui.geometry.CornerRadius(min(w, hh) / 2f))
        }
        MochiSpec.Eye.Flat -> {
            drawRoundRect(ink, Offset(-w * 0.72f, -w * 0.2f), Size(w * 1.44f, w * 0.4f),
                cornerRadius = androidx.compose.ui.geometry.CornerRadius(w * 0.2f))
        }
        MochiSpec.Eye.Happy -> {
            drawArc(ink, startAngle = 192f, sweepAngle = -204f, useCenter = false,
                topLeft = Offset(-w * 0.82f, h * 0.18f - w * 0.82f),
                size = Size(w * 1.64f, w * 1.64f),
                style = Stroke(width = w * 0.5f, cap = androidx.compose.ui.graphics.StrokeCap.Round))
        }
        MochiSpec.Eye.Closed -> {
            drawArc(ink, startAngle = 15f, sweepAngle = 150f, useCenter = false,
                topLeft = Offset(-w * 0.78f, -h * 0.08f - w * 0.78f),
                size = Size(w * 1.56f, w * 1.56f),
                style = Stroke(width = w * 0.36f, cap = androidx.compose.ui.graphics.StrokeCap.Round))
        }
        MochiSpec.Eye.Tired -> {
            drawRoundRect(ink, Offset(-w / 2, -h * 0.02f), Size(w, h * 0.38f),
                cornerRadius = androidx.compose.ui.geometry.CornerRadius(w / 2f))
            drawRoundRect(ink, Offset(-w * 0.62f, -h * 0.1f), Size(w * 1.24f, h * 0.22f),
                cornerRadius = androidx.compose.ui.geometry.CornerRadius(h * 0.11f))
        }
        MochiSpec.Eye.Spiral -> {
            val p = Path()
            var a = 0f
            while (a < 4.4f * PI.toFloat()) {
                val r = w * 0.06f + a * w * 0.058f
                val aa = a + t * 9f * sd
                val px = cos(aa) * r
                val py = sin(aa) * r
                if (a == 0f) p.moveTo(px, py) else p.lineTo(px, py)
                a += 0.2f
            }
            drawPath(p, ink, style = Stroke(width = w * 0.22f,
                cap = androidx.compose.ui.graphics.StrokeCap.Round))
        }
    }
}

private fun DrawScope.drawBadge(badge: MochiSpec.Badge, color: Color, R: Float, t: Float) {
    when (badge) {
        MochiSpec.Badge.Dots -> {
            // Mini: black disc + pulsing coloured dot.
            drawCircle(Color.Black, R * 0.2f)
            val phase = (t * 2.4f) % 1f
            drawCircle(color, R * 0.22f * (1f + 0.25f * sin(phase * 2f * PI.toFloat())))
        }
        MochiSpec.Badge.Bang, MochiSpec.Badge.Question -> {
            // Mini: black ring + coloured core, no glyph.
            drawCircle(Color.Black, R * 0.3f)
            drawCircle(color, R * 0.23f)
        }
        MochiSpec.Badge.Dot -> {
            drawCircle(Color.Black, R * 0.2f)
            drawCircle(color, R * 0.135f)
        }
    }
}
