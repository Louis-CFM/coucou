package com.coucou.android.core

import com.coucou.android.link.PairingPayload

/** What to do with text that came out of the camera. */
sealed interface ScanDecision {
    /** A well-formed Coucou pairing link: ask the user to confirm, then pair like a pasted link. */
    data class Pairing(val link: String) : ScanDecision

    /** Anything else (a website, a Wi-Fi code, a shop's QR): ignored, with a short hint. */
    data object NotPairing : ScanDecision
}

object PairingScan {
    /**
     * Uses the very parser that pasting uses, so a scanned code and a pasted link are accepted and refused
     * for the same reasons. The text is returned untouched (apart from trimming) and never logged.
     */
    fun decide(text: String?): ScanDecision {
        val t = text?.trim().orEmpty()
        if (t.isEmpty() || t.length > MAX_LINK) return ScanDecision.NotPairing
        return if (PairingPayload.parse(t) != null) ScanDecision.Pairing(t) else ScanDecision.NotPairing
    }

    /** A real pairing link is a few hundred characters (up to about 900 with the relay fields and a long, accented name); anything far longer is not one. */
    const val MAX_LINK = 2_048
}

/** Where the camera permission stands, for the scan screen. */
object ScanPermission {
    enum class State {
        /** The camera may be used. */
        GRANTED,
        /** Show the one-line reason and the "Allow camera" button. */
        ASK,
        /** Refused for good: Android will not ask again, so point to its settings or to pasting. */
        BLOCKED,
    }

    /**
     * [askedBefore]: we have shown Android's prompt at least once. [canExplain]: Android says the prompt can
     * still be shown (it was refused once, not for good).
     */
    fun state(granted: Boolean, askedBefore: Boolean, canExplain: Boolean): State = when {
        granted -> State.GRANTED
        !askedBefore -> State.ASK
        canExplain -> State.ASK
        else -> State.BLOCKED
    }
}
