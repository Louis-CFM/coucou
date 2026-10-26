package com.coucou.android.link

import com.coucou.android.core.Texts

/**
 * What the phone knows about the health of the link, in plain terms, so Home can say what happened ("Connection lost 2 min ago,
 * reconnecting") instead of showing a silent state. Pure: the clock is passed in, so every sentence is a unit test.
 */
data class LinkHealth(
    /** When the link that had been working ended (null: it never did, or it is back). */
    val lostAtMs: Long? = null,
    val reason: LostReason? = null,
    /** Failed attempts since then. */
    val attempts: Int = 0,
    /** How many times a link ended on its own after the screen had been off (this is what the battery hint is about). */
    val dropsWhileScreenOff: Int = 0,
) {
    fun lost(atMs: Long, why: LostReason, screenWasOff: Boolean) =
        copy(lostAtMs = atMs, reason = why, attempts = 0, dropsWhileScreenOff = dropsWhileScreenOff + if (screenWasOff) 1 else 0)

    fun failedAttempt(count: Int) = copy(attempts = count)

    /** Connected again: the story is over (the number of drops while the screen was off stays). */
    fun recovered() = copy(lostAtMs = null, reason = null, attempts = 0)
}

object LinkHealthText {
    /** "less than a minute", "2 min", "1 h 5 min", "3 h". */
    fun ago(ms: Long): String {
        val minutes = (ms.coerceAtLeast(0) / 60_000).toInt()
        return when {
            minutes < 1 -> Texts.t("ago_less_than_minute", "less than a minute")
            minutes < 60 -> Texts.t("ago_minutes", "%1\$d min", minutes)
            minutes % 60 == 0 -> Texts.t("ago_hours", "%1\$d h", minutes / 60)
            else -> Texts.t("ago_hours_minutes", "%1\$d h %2\$d min", minutes / 60, minutes % 60)
        }
    }

    /**
     * The most likely cause in plain words, from what the link layer knows: why the link ended and whether the phone is on Wi-Fi. The
     * phone cannot see the computer's side, so a cause it cannot know is a short list of what to look at, never a guess stated as fact.
     */
    fun why(reason: LostReason?, wifiUp: Boolean = true) = when (reason) {
        LostReason.SILENT -> Texts.t("lost_silent", "The computer stopped answering. This is usual after the phone slept.")
        LostReason.CLOSED -> Texts.t("lost_closed", "The computer closed the connection. Coucou may have been closed or restarted there.")
        LostReason.NETWORK ->
            if (!wifiUp) Texts.t("lost_no_wifi", "The phone is not on Wi-Fi. Join the network your computer is on, or use the internet link.")
            else Texts.t("lost_unreachable", "The phone cannot reach the computer. Coucou may be closed there, its phone link may be off, or it is on another network.")
        null -> ""
    }

    /** The two lines for Home while the link is down after having worked; null when there is nothing to say. */
    fun lines(connected: Boolean, health: LinkHealth, nowMs: Long, wifiUp: Boolean = true): Pair<String, String>? {
        val at = health.lostAtMs ?: return null
        if (connected) return null
        val head = Texts.t("lost_head", "Connection lost %1\$s ago, reconnecting", ago(nowMs - at)) +
            if (health.attempts >= 3) " " + Texts.t("lost_tries", "(%1\$d tries)", health.attempts) else ""
        return head to why(health.reason, wifiUp)
    }
}

/** The alarm that keeps the link honest while the phone sleeps (see docs/ANDROID_LINK.md, "Keeping the link alive"). */
object KeepAlivePolicy {
    /**
     * How often the alarm asks for a check. Android may delay it in Doze (to about 9 minutes, or a maintenance window), never make it
     * more frequent. The computer allows [COMPUTER_IDLE_MS] of silence, which is several times longer.
     */
    const val INTERVAL_MS = 4 * 60_000L
    /** How long the computer tolerates silence from an authenticated phone (windows/src-tauri/.../server.rs, IDLE_TIMEOUT). */
    const val COMPUTER_IDLE_MS = 20 * 60_000L
    /** The wake lock held during one check, only so the question and its answer can cross; released as soon as it is done. */
    const val WAKE_LOCK_MS = 15_000L

    /** An alarm exists only while a real computer is paired. */
    fun shouldArm(paired: Boolean, demo: Boolean) = paired && !demo
}

/**
 * When to suggest the battery setting. Only when it would help: the link ended on its own after the screen had been off, the
 * app is still restricted, and the user did not say "not now" recently.
 */
object BatteryHint {
    const val SNOOZE_MS = 7 * 24 * 3_600_000L

    fun shouldShow(paired: Boolean, health: LinkHealth, ignoringOptimizations: Boolean, snoozedAtMs: Long?, nowMs: Long): Boolean =
        paired && !ignoringOptimizations && health.dropsWhileScreenOff >= 1 &&
            (snoozedAtMs == null || nowMs - snoozedAtMs >= SNOOZE_MS)

    /** Where to look: Samsung hides the setting in two places. */
    fun isSamsung(manufacturer: String) = manufacturer.equals("samsung", ignoreCase = true)

    fun steps(samsung: Boolean): List<String> =
        if (samsung) listOf(
            Texts.t("battery_step_samsung_1", "Open Settings > Apps > Coucou for Android > Battery and choose Unrestricted."),
            Texts.t("battery_step_samsung_2", "Then Settings > Battery > Background usage limits: make sure Coucou is not in Sleeping apps or Deep sleeping apps (add it to Never sleeping apps)."),
        ) else listOf(
            Texts.t("battery_step_generic", "Open the app's battery setting and choose Unrestricted (or Don't optimise)."),
        )
}
