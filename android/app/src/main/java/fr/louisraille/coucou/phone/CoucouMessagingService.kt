package fr.louisraille.coucou.phone

import android.util.Log
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * Pushes are data-only {k, t} — kind + timestamp, never content — so every
 * message just means "go read the box". On a fresh card we post the heads-up;
 * when nothing waits any more we clear a stale one.
 */
class CoucouMessagingService : FirebaseMessagingService() {

    override fun onNewToken(token: String) {
        // Rotated token: re-claim the same box so the PC keeps reaching us.
        val p = Prefs.load(this) ?: return
        Thread {
            try {
                Relay.claim(p, token)
            } catch (_: Exception) { /* next claim attempt happens on app open */ }
        }.start()
    }

    override fun onMessageReceived(message: RemoteMessage) {
        Log.w("CoucouPush", "onMessageReceived data=${message.data}")
        val p = Prefs.load(this)
        if (p == null) { Log.w("CoucouPush", "no prefs"); return }
        Thread {
            try {
                val f = Relay.fetch(p)
                val card = f.pending
                Log.w("CoucouPush", "fetch ok card=${card?.requestId}")
                if (card != null) Notifier.showCard(this, card) else Notifier.cancelCard(this)
            } catch (e: Exception) {
                Log.w("CoucouPush", "fetch failed: $e")
            }
        }.start()
    }
}
