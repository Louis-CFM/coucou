package com.coucou.android.core


/**
 * When the small pill drops from the top of the screen, like the notch on the computer: it stays
 * out of sight, wakes when an agent finishes, fails, asks something or is rate limited, shows for a
 * moment, then slides away. A permission request is not here: it has its own card that stays until
 * it is answered.
 */
object OverlayPolicy {
    /** The pill is for when you are in another app; inside Coucou the screen already shows it. */
    fun shouldShow(enabled: Boolean, permitted: Boolean, appInForeground: Boolean): Boolean =
        blocker(enabled, permitted, appInForeground) == null

    /**
     * A tap in the first moments is most likely meant for the app underneath (the pill slides in over
     * it) or lands by accident. Buttons and the body of the pill ignore it.
     */
    const val TAP_GUARD_MS = 600.0

    fun tapAccepted(shownAtMs: Double, nowMs: Double): Boolean = nowMs - shownAtMs >= TAP_GUARD_MS

    /**
     * How a permission request is announced. When the pill is on screen it is the one thing that
     * appears; the notification still goes to the shade, quietly, as the fallback. Otherwise the
     * notification is what tells the user (heads-up and sound).
     */
    enum class ApprovalAlert { HEADS_UP, QUIET }

    fun approvalAlert(pillShown: Boolean): ApprovalAlert = if (pillShown) ApprovalAlert.QUIET else ApprovalAlert.HEADS_UP

    /** Why the pill stays away (for the log), or null when it may show. */
    fun blocker(enabled: Boolean, permitted: Boolean, appInForeground: Boolean): String? = when {
        !enabled -> "switch is off"
        !permitted -> "'display over other apps' is not allowed"
        appInForeground -> "the app is on screen"
        else -> null
    }
}

/** Where the user's wish is kept (SharedPreferences in the app, a plain object in tests). */
interface WishStore {
    fun read(): Boolean
    fun write(on: Boolean)
}

/**
 * The switch "Show Mochi over other apps". The wish is saved the moment the user taps, before the
 * system permission screen opens: if Android recreates the activity or the process while the user is
 * in Settings, nothing is lost. The permission is asked live each time, so granting it later from
 * Android's own settings makes the pill work without another tap.
 */
class OverlayChoice(private val store: WishStore) {
    val wished: Boolean get() = store.read()
    fun choose(on: Boolean) = store.write(on)

    /** What the switch shows, and whether the pill may exist. */
    fun active(permitted: Boolean): Boolean = wished && permitted
}
