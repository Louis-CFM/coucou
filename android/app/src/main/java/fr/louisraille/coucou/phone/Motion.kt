package fr.louisraille.coucou.phone

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.pow

/**
 * Coucou's motion on the phone, ported from upstream core/Anim.kt +
 * core/IslandMotion.kt (itself a port of windows/src/core/anim.ts, which mirrors
 * CoucouKit's BotEngine `enum Ease`): growing is a spring (response 0.5 s,
 * damping 0.72), shrinking and retracting is a 340 ms timed curve
 * cubic-bezier(.45, 0, .2, 1) with no overshoot. No Android dependency, so a
 * test can check the physics.
 */
typealias EaseFn = (Double) -> Double

object Ease {
    val out: EaseFn = { t -> 1 - (1 - t).pow(3) }
    val inOut: EaseFn = { t -> if (t < 0.5) 4 * t * t * t else 1 - (-2 * t + 2).pow(3) / 2 }
    val back: EaseFn = { t ->
        val c1 = 1.7
        val c3 = c1 + 1
        1 + c3 * (t - 1).pow(3) + c1 * (t - 1).pow(2)
    }
    val lin: EaseFn = { t -> t }
    val easeIn: EaseFn = { t -> t * t * t }
}

fun lerp(a: Double, b: Double, t: Double): Double = a + (b - a) * t

fun cubicBezier(x1: Double, y1: Double, x2: Double, y2: Double): EaseFn {
    fun cx(t: Double) = (1 - t) * (1 - t) * 3 * t * x1 + 3 * (1 - t) * t * t * x2 + t * t * t
    fun cy(t: Double) = (1 - t) * (1 - t) * 3 * t * y1 + 3 * (1 - t) * t * t * y2 + t * t * t
    return { x ->
        var lo = 0.0
        var hi = 1.0
        var t = x
        repeat(12) {
            if (cx(t) < x) lo = t else hi = t
            t = (lo + hi) / 2
        }
        cy(t)
    }
}

val closeCurve: EaseFn = cubicBezier(0.45, 0.0, 0.2, 1.0)

class Spring(var value: Double, response: Double = 0.5, damping: Double = 0.72) {
    var target = value
    var velocity = 0.0
    private var omega = 2 * PI / response
    private var zeta = damping

    fun configure(response: Double, damping: Double) {
        omega = 2 * PI / response
        zeta = damping
    }

    val settled: Boolean get() = abs(target - value) < 0.01 && abs(velocity) < 0.05

    /** Sub-stepped at 1/240 s so a dropped frame never destabilises it. */
    fun step(dt: Double) {
        val steps = max(1, ceil(dt / (1.0 / 240)).toInt())
        val h = dt / steps
        repeat(steps) {
            val acc = omega * omega * (target - value) - 2 * zeta * omega * velocity
            velocity += acc * h
            value += velocity * h
        }
    }
}

/** A value driven by a spring when it grows and by the close curve when it shrinks (the PC's IslandContainer). */
class Tracked(initial: Double) {
    private val spring = Spring(initial)
    private var curveFrom = 0.0
    private var curveTo = 0.0
    private var curveStartMs = 0.0
    private var curveDurMs = 0.0
    private enum class Mode { SPRING, CURVE, IDLE }
    private var mode = Mode.IDLE

    val value: Double get() = spring.value
    val animating: Boolean get() = mode != Mode.IDLE

    fun jump(v: Double) {
        spring.value = v
        spring.target = v
        spring.velocity = 0.0
        mode = Mode.IDLE
    }

    fun springTo(v: Double, response: Double = 0.5, damping: Double = 0.72) {
        spring.configure(response, damping)
        spring.target = v
        mode = Mode.SPRING
    }

    fun curveTowards(v: Double, nowMs: Double, durationMs: Double = MotionSpec.RETRACT_MS.toDouble()) {
        curveFrom = spring.value
        curveTo = v
        curveStartMs = nowMs
        curveDurMs = durationMs
        spring.target = v
        spring.velocity = 0.0
        mode = Mode.CURVE
    }

    /** Grow with the spring, shrink with the curve (what the PC does on every size change). */
    fun goTo(v: Double, nowMs: Double) {
        if (v < value) curveTowards(v, nowMs) else springTo(v)
    }

    fun step(dtSeconds: Double, nowMs: Double) {
        when (mode) {
            Mode.SPRING -> {
                spring.step(dtSeconds)
                if (spring.settled) {
                    spring.value = spring.target
                    spring.velocity = 0.0
                    mode = Mode.IDLE
                }
            }
            Mode.CURVE -> {
                val p = ((nowMs - curveStartMs) / curveDurMs).coerceIn(0.0, 1.0)
                // The bisection leaves a hair of error at the ends: land exactly on the target.
                spring.value = if (p >= 1) curveTo else lerp(curveFrom, curveTo, closeCurve(p))
                if (p >= 1) {
                    spring.velocity = 0.0
                    mode = Mode.IDLE
                }
            }
            Mode.IDLE -> Unit
        }
    }
}

/** Motion constants shared with the PC. */
object MotionSpec {
    const val RETRACT_MS = 340
    /** With "remove animations" on, a spring or a slide becomes this fade. */
    const val REDUCED_MS = 120

    /** Android's "Remove animations" (and developer "animator duration scale: off") sets the scale to 0. */
    fun isReduced(animatorDurationScale: Float): Boolean = animatorDurationScale <= 0f
}
