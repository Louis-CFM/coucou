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
        // Approvals get inline buttons; questions need the app's option UI, tap opens it.
        if (!card.isQuestion) {
            b.addAction(0, ctx.getString(R.string.allow), decisionPending(ctx, card, "allow", 1))
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
