package com.coucou.android.sound

/** Volume rules from docs/SPEC.md: default 0.12 and the slider never goes above 0.2. */
object SoundVolume {
    const val DEFAULT = 0.12f
    const val MAX = 0.2f
    fun clamp(v: Float): Float = v.coerceIn(0f, MAX)
}
