package com.coucou.android.mochi

/** Components 0..1, like the TS `RGB` tuple. */
data class Rgb(val r: Double, val g: Double, val b: Double) {
    fun mix(o: Rgb, t: Double) = Rgb(r + (o.r - r) * t, g + (o.g - g) * t, b + (o.b - b) * t)
}

enum class EyeShape { PILL, WIDE, DOT, LINE, FLAT, HAPPY, CLOSED, SPIRAL, HEART, STAR, TIRED, WINK, CUP }

enum class BadgeKind { DOTS, BANG, QUESTION, DOT }

data class Badge(val kind: BadgeKind, val color: Rgb)

enum class BotState(val key: String) {
    IDLE("idle"), WORKING("working"), THINKING("thinking"), SEARCHING("searching"),
    APPROVAL("approval"), QUESTION("question"), ERROR("error"), FINISHED("finished"),
    RATELIMIT("ratelimit"), SLEEPING("sleeping"), DIZZY("dizzy"),
}

enum class BotEmote(val key: String) {
    LOVE("love"), SURPRISED("surprised"), PROUD("proud"), WINK("wink"),
    YAWN("yawn"), HAPPY("happy"), ANNOYED("annoyed"),
}

data class BotStateCfg(
    val color: Rgb,
    val tint: Double,
    val eye: EyeShape,
    val badge: Badge?,
    val bounces: Boolean = false,
    val scans: Boolean = false,
    val breathes: Boolean = false,
    val zz: Boolean = false,
    val sweat: Boolean = false,
    val look: Pair<Double, Double>? = null,
    val tilt: Double = 0.0,
)

object MochiConst {
    const val EYE_W = 0.25
    const val EYE_H = 0.27
    const val EYE_SP = 0.37
    const val EYE_P = -0.12
    val BASE_TOP = Rgb(0.929, 0.929, 0.937)    // #EDEDEF
    val BASE_BOTTOM = Rgb(0.769, 0.773, 0.792) // #C4C5CA

    val C_IDLE = Rgb(0.902, 0.914, 0.933)
    val C_WORKING = Rgb(0.231, 0.62, 1.0)
    val C_THINKING = Rgb(0.545, 0.361, 0.965)
    val C_SEARCHING = Rgb(0.388, 0.396, 0.949)
    val C_APPROVAL = Rgb(0.961, 0.647, 0.141)
    val C_QUESTION = Rgb(0.133, 0.827, 0.933)
    val C_ERROR = Rgb(0.957, 0.314, 0.369)
    val C_FINISHED = Rgb(0.204, 0.831, 0.6)
    val C_RATELIMIT = Rgb(0.984, 0.573, 0.235)
    val C_SLEEPING = Rgb(0.58, 0.635, 0.722)
    val C_DIZZY = Rgb(0.957, 0.447, 0.714)

    val STATES: Map<BotState, BotStateCfg> = mapOf(
        BotState.IDLE to BotStateCfg(C_IDLE, 0.0, EyeShape.PILL, null),
        BotState.WORKING to BotStateCfg(C_WORKING, 0.72, EyeShape.PILL, Badge(BadgeKind.DOTS, C_WORKING)),
        BotState.THINKING to BotStateCfg(C_THINKING, 0.72, EyeShape.PILL, Badge(BadgeKind.DOTS, C_THINKING), look = 0.55 to 0.55),
        BotState.SEARCHING to BotStateCfg(C_SEARCHING, 0.72, EyeShape.PILL, Badge(BadgeKind.DOTS, C_SEARCHING), scans = true),
        BotState.APPROVAL to BotStateCfg(C_APPROVAL, 0.78, EyeShape.WIDE, Badge(BadgeKind.BANG, C_APPROVAL), bounces = true),
        BotState.QUESTION to BotStateCfg(C_QUESTION, 0.75, EyeShape.PILL, Badge(BadgeKind.QUESTION, C_QUESTION), tilt = 0.17),
        BotState.ERROR to BotStateCfg(C_ERROR, 0.78, EyeShape.FLAT, Badge(BadgeKind.DOT, C_ERROR)),
        BotState.FINISHED to BotStateCfg(C_FINISHED, 0.35, EyeShape.HAPPY, Badge(BadgeKind.DOT, C_FINISHED)),
        BotState.RATELIMIT to BotStateCfg(C_RATELIMIT, 0.72, EyeShape.TIRED, Badge(BadgeKind.DOT, C_RATELIMIT), sweat = true),
        BotState.SLEEPING to BotStateCfg(C_SLEEPING, 0.32, EyeShape.CLOSED, null, breathes = true, zz = true),
        BotState.DIZZY to BotStateCfg(C_DIZZY, 0.7, EyeShape.SPIRAL, null),
    )

    /** State to sound file name (res/raw), as STATE_SOUND in engine.ts. */
    val STATE_SOUND: Map<BotState, String> = mapOf(
        BotState.WORKING to "work", BotState.THINKING to "think", BotState.SEARCHING to "search",
        BotState.APPROVAL to "approval", BotState.QUESTION to "question", BotState.ERROR to "error",
        BotState.FINISHED to "finish", BotState.RATELIMIT to "rate", BotState.SLEEPING to "sleep",
        BotState.DIZZY to "dizzy",
    )

    val EMOTE_EYE: Map<BotEmote, EyeShape> = mapOf(
        BotEmote.LOVE to EyeShape.HEART, BotEmote.SURPRISED to EyeShape.DOT, BotEmote.PROUD to EyeShape.STAR,
        BotEmote.WINK to EyeShape.WINK, BotEmote.YAWN to EyeShape.TIRED, BotEmote.HAPPY to EyeShape.HAPPY,
        BotEmote.ANNOYED to EyeShape.LINE,
    )
}
