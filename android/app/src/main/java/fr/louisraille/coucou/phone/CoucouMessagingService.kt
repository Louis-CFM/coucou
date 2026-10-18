package fr.louisraille.coucou.phone

import android.util.Log
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import fr.louisraille.coucou.phone.widget.CoucouWidget
import kotlinx.coroutines.runBlocking

/**
 * Pushes are data-only {k, t} — kind + timestamp, never content — so every
 * message just means "go read the box". On a fresh card we post the heads-up;
 * when nothing waits any more we clear a stale one.
 */
class CoucouMessagingService : FirebaseMessagingService() {

    override fun onNewToken(token: String) {
        // Called on FCM's background thread, with time to finish: no Thread{}
        // the system may freeze before the claim goes out.
        val p = Prefs.load(this) ?: return
        try {
            Relay.claim(p, token)
            Prefs.setClaimedToken(this, token)
        } catch (_: Exception) {
            // The app claims it the next time it comes forward (TokenSync).
        }
    }

    override fun onMessageReceived(message: RemoteMessage) {
        // Already on FCM's background thread, which waits for us: returning
        // early (a Thread{}) let the system freeze the app mid-fetch.
        val p = Prefs.load(this) ?: return
        try {
            val f = Relay.fetch(p)
            val card = f.pending
            if (card != null) Notifier.showCard(this, card) else Notifier.cancelCard(this)
            // The persistent status line and the home widget follow what the
            // push just showed.
            f.state?.sessions?.let { s ->
                Notifier.updateLive(this, s)
                runBlocking { CoucouWidget.push(this@CoucouMessagingService, s) }
            }
        } catch (e: Exception) {
            if (BuildConfig.DEBUG) Log.w("CoucouPush", "fetch failed", e)
        }
    }
}
