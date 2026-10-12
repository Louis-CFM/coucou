package fr.louisraille.coucou.phone

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/** Heads-up "coucou-alerts" — the Android stand-in for the iPhone Live Activity. */
object Notifier {
    const val CHANNEL = "coucou-alerts"
    const val CARD_ID = 7001

    /** The PC holds a card for 108 s (pipe.rs DECISION_TIMEOUT); after that its buttons do nothing. */
    private const val CARD_TTL_MS = 108_000L

    fun ensureChannel(ctx: Context) {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL, ctx.getString(R.string.channel_alerts), NotificationManager.IMPORTANCE_HIGH)
        )
    }

    private fun decisionPending(ctx: Context, card: Relay.Card, decision: String, req: Int): PendingIntent {
        val i = Intent(ctx, DecisionReceiver::class.java)
            .putExtra(DecisionReceiver.EXTRA_REQUEST, card.requestId)
            .putExtra(DecisionReceiver.EXTRA_DECISION, decision)
        return PendingIntent.getBroadcast(
            ctx, req, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    fun showCard(ctx: Context, card: Relay.Card) {
        ensureChannel(ctx)
        val tap = PendingIntent.getActivity(
            ctx, 0,
            Intent(ctx, MainActivity::class.java)
                .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val b = NotificationCompat.Builder(ctx, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_coucou)
            .setContentTitle(card.title.ifBlank { card.agent })
            .setContentText(card.detail.ifBlank { card.agent })
            .setStyle(NotificationCompat.BigTextStyle().bigText(card.detail.ifBlank { card.title }))
            .setSubText(card.agent)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(tap)
            .setTimeoutAfter(CARD_TTL_MS)
        // Approvals get inline buttons; questions need the app's option UI, tap opens it.
        if (!card.isQuestion) {
            // Allow first unlocks the phone, as the in-app Allow asks for the
            // fingerprint (gateWithBiometrics). Deny stays a plain tap there too.
            b.addAction(
                NotificationCompat.Action.Builder(0, ctx.getString(R.string.allow), decisionPending(ctx, card, "allow", 1))
                    .setAuthenticationRequired(true)
                    .build(),
            )
            b.addAction(0, ctx.getString(R.string.deny), decisionPending(ctx, card, "deny", 2))
        }
        try {
            NotificationManagerCompat.from(ctx).notify(CARD_ID, b.build())
        } catch (_: SecurityException) {
            // POST_NOTIFICATIONS not granted — the card is still there next app open.
        }
    }

    fun cancelCard(ctx: Context) {
        NotificationManagerCompat.from(ctx).cancel(CARD_ID)
    }
}
