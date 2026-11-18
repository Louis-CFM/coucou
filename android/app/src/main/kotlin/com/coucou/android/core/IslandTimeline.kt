package com.coucou.android.core

import com.coucou.android.mochi.BotState

/** What the island shows. [pillId] is the session it is about (or the request's pill). */
data class IslandSpec(
    val kind: Kind,
    val pillId: String,
    val agent: String,
    val state: BotState,
    val text: String,
    /** The request this is about (approvals only): what Allow and Deny act on. */
    val fingerprint: String? = null,
    /** False for a request whose command could not be shown in full: the island offers Deny only. */
    val canAllow: Boolean = true,
) {
    enum class Kind { WORKING, QUESTION, APPROVAL, FINISHED, ERROR, RATELIMIT }

    /** Working, a question and a permission request stay until something changes. */
    val persistent: Boolean get() = kind == Kind.WORKING || kind == Kind.QUESTION || kind == Kind.APPROVAL
}

/**
 * When the island is open and when it goes back up into the notch, with an injectable clock.
 *
 * - [setActive]: what is going on right now (working, a question, a request). It needs no deadline.
 * - [flash]: a finished, failed or rate-limited event. Held [HOLD_MS] (10 s, as the user asked), then
 *   the island retracts. A newer event restarts the hold.
 * - The island re-opens when something starts while it is retracting; a content change (working to
 *   finished) never retracts it.
 * - [nextDeadline] is the only time anything must wake up: while hidden it is null, so nothing runs.
 */
class IslandTimeline(private val clockMs: () -> Double) {
    enum class Phase { HIDDEN, OPEN, RETRACTING }

    var phase = Phase.HIDDEN
        private set

    private var active: IslandSpec? = null
    private var flash: IslandSpec? = null
    private var flashUntil = 0.0
    private var retractUntil = 0.0

    /** What to draw now (kept while retracting, so the island shrinks around its last content). */
    var current: IslandSpec? = null
        private set

    fun setActive(spec: IslandSpec?) {
        active = spec
        refresh()
    }

    fun flash(spec: IslandSpec) {
        flash = spec
        flashUntil = clockMs() + HOLD_MS
        refresh()
    }

    /** Close at once (Coucou came to the front, the switch went off, the link dropped). */
    fun dismiss() {
        active = null
        flash = null
        current = null
        phase = Phase.HIDDEN
    }

    /** Call when [nextDeadline] has passed. */
    fun tick() = refresh()

    /** The island has finished moving up: its window can go. */
    fun retractFinished() {
        if (phase == Phase.RETRACTING) {
            phase = Phase.HIDDEN
            current = null
        }
    }

    /** Absolute clock time of the next change, or null when nothing is scheduled (hidden, or persistent content). */
    fun nextDeadline(): Double? = when (phase) {
        Phase.HIDDEN -> null
        Phase.RETRACTING -> retractUntil
        Phase.OPEN -> if (active == null && flash != null) flashUntil else null
    }

    private fun refresh() {
        val now = clockMs()
        if (flash != null && now >= flashUntil) flash = null
        val shown = active ?: flash
        when {
            shown != null -> {
                current = shown
                phase = Phase.OPEN
            }
            phase == Phase.OPEN -> {
                // Nothing left to show: go back up. The content stays for the animation.
                phase = Phase.RETRACTING
                retractUntil = now + RETRACT_MS
            }
            phase == Phase.RETRACTING && now >= retractUntil -> retractFinished()
        }
    }

    companion object {
        const val HOLD_MS = 10_000.0
        const val RETRACT_MS = Tracked.CLOSE_MS
    }
}
