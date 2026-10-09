package fr.louisraille.coucou.phone

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Notification Allow/Deny buttons land here; they POST decide straight to the box. */
class DecisionReceiver : BroadcastReceiver() {

    companion object {
        const val EXTRA_REQUEST = "requestId"
        const val EXTRA_DECISION = "decision"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val p = Prefs.load(context) ?: return
        val requestId = intent.getStringExtra(EXTRA_REQUEST) ?: return
        val decision = intent.getStringExtra(EXTRA_DECISION) ?: return
        val pending = goAsync()
        Thread {
            try {
                Relay.decide(p, requestId, decision, null)
            } catch (_: Exception) { /* a stale card is simply ignored by the PC */ }
            Notifier.cancelCard(context)
            pending.finish()
        }.start()
    }
}
