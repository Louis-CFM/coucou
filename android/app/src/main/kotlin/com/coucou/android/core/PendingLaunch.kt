package com.coucou.android.core

/**
 * "Open the app on Allow for this request", handed from our own notification tap to the main screen inside the
 * process. MainActivity is exported (it is the launcher and takes coucou:// links), so it must never trust extras on
 * the intent it is started with: another app could send the same ones and pop the Allow prompt. Only the non-exported
 * LaunchActivity, started by our own PendingIntents, calls [request]; MainActivity only calls [take].
 */
class PendingLaunch(private val clock: () -> Long = System::currentTimeMillis) {
    data class Request(val fingerprint: String, val allow: Boolean)

    private var fingerprint: String? = null
    private var allow = false
    private var at = 0L

    @Synchronized
    fun request(fp: String?, allow: Boolean) {
        val clean = fp?.takeIf { it.isNotBlank() && it.length <= MAX_FP }
        this.fingerprint = clean
        this.allow = allow && clean != null
        this.at = clock()
    }

    /** The request once, if it is fresh; null for everything else (nothing asked, already taken, too old). */
    @Synchronized
    fun take(): Request? {
        val fp = fingerprint ?: return null
        val fresh = clock() - at <= TTL_MS
        val a = allow
        fingerprint = null
        allow = false
        return if (fresh) Request(fp, a) else null
    }

    companion object {
        /** The tap and the screen are in the same second; a longer wait means something else is going on. */
        const val TTL_MS = 15_000L
        const val MAX_FP = 128
    }
}
