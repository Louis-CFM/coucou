package com.coucou.android.core

import kotlin.math.pow

/** Port of windows/src/core/anim.ts (Ease mirrors BotEngine.swift `enum Ease`). */
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
