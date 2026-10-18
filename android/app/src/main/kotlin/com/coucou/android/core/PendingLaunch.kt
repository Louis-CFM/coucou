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

    private var session: String? = null
    private var sessionAt = 0L

    private var screen: LaunchScreen? = null
    private var screenAt = 0L

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

    /**
     * "Open this session", from a tap on a widget row. A slot of its own: it never carries an Allow, and an Allow
     * request never opens a session. Only the non-exported LaunchActivity calls it.
     */
    @Synchronized
    fun requestSession(pillId: String?) {
        session = pillId?.takeIf { it.isNotBlank() && it.length <= MAX_PILL }
        sessionAt = clock()
    }

    /** The pill id of the session to open, once, if the tap is fresh; null for everything else. */
    @Synchronized
    fun takeSession(): String? {
        val id = session ?: return null
        val fresh = clock() - sessionAt <= TTL_MS
        session = null
        return if (fresh) id else null
    }

    /**
     * "Open this screen", from a Widget button. A slot of its own, holding a value of the closed [LaunchScreen] list and
     * nothing else: it never carries an Allow or a session, and they never carry a screen. Only the non-exported
     * LaunchActivity calls it.
     */
    @Synchronized
    fun requestScreen(which: LaunchScreen?) {
        screen = which
        screenAt = clock()
    }

    /** The screen to open, once, if the tap is fresh; null for everything else (nothing asked, already taken, too old). */
    @Synchronized
    fun takeScreen(): LaunchScreen? {
        val s = screen ?: return null
        val fresh = clock() - screenAt <= TTL_MS
        screen = null
        return if (fresh) s else null
    }

    companion object {
        const val MAX_PILL = 64
        /** The tap and the screen are in the same second; a longer wait means something else is going on. */
        const val TTL_MS = 15_000L
        const val MAX_FP = 128
    }
}
