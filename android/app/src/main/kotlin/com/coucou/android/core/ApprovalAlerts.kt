package com.coucou.android.core

/**
 * How a request for permission buzzes the phone. The approval is never muted or hidden by any of these choices: it is always a
 * heads-up notification with Mochi's sound; only the buzz changes (and the Settings choice "Don't wake the screen" only stops the
 * screen from lighting up, the notification is still posted).
 */
enum class VibrationChoice(val key: String, val pattern: LongArray?) {
    /** Today's pattern: two half-second buzzes. */
    STANDARD("standard", longArrayOf(0, 500, 150, 500)),
    SHORT("short", longArrayOf(0, 200)),
    OFF("off", null);

    companion object {
        /** An unknown or missing key is today's behaviour. */
        fun parse(key: String?): VibrationChoice = values().firstOrNull { it.key == key } ?: STANDARD
    }
}

/**
 * The notification channel of approvals. Android never lets an app change the vibration of a channel after it exists, so each choice
 * has its own id; only the chosen one exists at a time (the others are deleted), so Android's own settings show a single "Approvals".
 * The standard id is the one the app has always used, so a user who changed that channel in Android's settings keeps the changes.
 */
object ApprovalChannels {
    const val STANDARD_ID = "approvals_v3"

    fun id(v: VibrationChoice): String = if (v == VibrationChoice.STANDARD) STANDARD_ID else "${STANDARD_ID}_${v.key}"

    /** The ids to delete when [v] is chosen. */
    fun othersThan(v: VibrationChoice): List<String> = VibrationChoice.values().filter { it != v }.map { id(it) }
}
