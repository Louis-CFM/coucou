package fr.louisraille.coucou.phone

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
        val p = Prefs.load(this) ?: return
        Thread {
            try {
                val f = Relay.fetch(p)
                val card = f.pending
                if (card != null) Notifier.showCard(this, card) else Notifier.cancelCard(this)
            } catch (_: Exception) { /* offline — the next push retries */ }
        }.start()
    }
}
