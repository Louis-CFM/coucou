package fr.louisraille.coucou.phone

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/**
 * Notifications: a loud card per waiting request, and a quiet ping when an
 * agent finishes, fails or hits a limit. Allow asks for the fingerprint,
 * Deny is a plain tap. On a locked screen nothing leaks: the public version
 * says "Approval needed", the command stays behind the unlock — the upstream
 * app's notification style, on our cloud-relay architecture.
 */
object Notifier {
    /** v2 carries Mochi's approval sound + a short buzz; channel options are immutable, so it got a new id. */
    const val CHANNEL = "coucou-alerts-v2"
    const val CHANNEL_UPDATES = "coucou-updates"
    /** The persistent status line — silent, sits at the bottom of the shade. */
    const val CHANNEL_LIVE = "coucou-live"
    const val CARD_ID = 7001
    private const val STATUS_ID = 8001
    private const val LIVE_ID = 8002

    /** The PC holds a card for 108 s (pipe.rs DECISION_TIMEOUT); after that its buttons do nothing. */
    private const val CARD_TTL_MS = 108_000L
    private const val WAKE_MS = 6_000L

    fun ensureChannel(ctx: Context) {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        nm.deleteNotificationChannel("coucou-alerts")
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL, ctx.getString(R.string.channel_alerts), NotificationManager.IMPORTANCE_HIGH).apply {
                // A short buzz, so a request is felt even when the notification volume is 0.
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 500, 150, 500)
                // Mochi's own approval sound, bundled in res/raw.
                setSound(
                    Uri.parse("${android.content.ContentResolver.SCHEME_ANDROID_RESOURCE}://${ctx.packageName}/${R.raw.approval}"),
                    AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION).build(),
                )
            },
        )
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_UPDATES, ctx.getString(R.string.channel_updates), NotificationManager.IMPORTANCE_LOW).apply {
                description = ctx.getString(R.string.channel_updates_desc)
                setShowBadge(false)
            },
        )
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_LIVE, ctx.getString(R.string.channel_live), NotificationManager.IMPORTANCE_MIN).apply {
                description = ctx.getString(R.string.channel_live_desc)
                setShowBadge(false)
            },
        )
    }

    private fun decisionPending(ctx: Context, card: Relay.Card, decision: String, req: Int): PendingIntent {
        // The request id rides in the data URI too: PendingIntent equality
        // ignores extras, so two waiting cards would otherwise share one
        // PendingIntent — the newer one's extras would win, and Allow on the
        // older card would decide the newer request.
        val i = Intent(ctx, DecisionReceiver::class.java)
            .setData(Uri.parse("coucou://decide/${card.requestId}/$decision"))
            .putExtra(DecisionReceiver.EXTRA_REQUEST, card.requestId)
            .putExtra(DecisionReceiver.EXTRA_DECISION, decision)
        return PendingIntent.getBroadcast(
            ctx, req, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    fun showCard(ctx: Context, card: Relay.Card) {
        ensureChannel(ctx)
        val tag = card.requestId
        val tap = PendingIntent.getActivity(
            ctx, 0,
            Intent(ctx, MainActivity::class.java)
                .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        // Lock screen: the request kind only — the title and detail wait behind the unlock.
        val publicVersion = NotificationCompat.Builder(ctx, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_coucou)
            .setContentTitle(ctx.getString(R.string.app_name))
            .setContentText(ctx.getString(R.string.notif_unlock))
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .build()
        val b = NotificationCompat.Builder(ctx, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_coucou)
            .setContentTitle(card.title.ifBlank { card.agent })
            .setContentText(card.detail.ifBlank { card.agent })
            .setStyle(NotificationCompat.BigTextStyle().bigText(card.detail.ifBlank { card.title }))
            .setSubText(card.agent)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(publicVersion)
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
            NotificationManagerCompat.from(ctx).notify(tag, CARD_ID, b.build())
        } catch (_: SecurityException) {
            // POST_NOTIFICATIONS not granted — the card is still there next app open.
        }
        if (!card.isQuestion) wakeScreen(ctx)
    }

    /**
     * A request on a sleeping phone lights the screen for a few seconds, so the lock
     * screen shows the notification ("Unlock to see the request"). The phone stays
     * locked; nothing about the command is shown.
     */
    @Suppress("DEPRECATION")
    private fun wakeScreen(ctx: Context) = runCatching {
        val pm = ctx.getSystemService(PowerManager::class.java)
        if (pm.isInteractive) return@runCatching
        pm.newWakeLock(
            PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
            "coucou:card",
        ).acquire(WAKE_MS)
    }

    /** An agent finished, failed, hit a limit or asks something — quiet, the card is the loud one. */
    fun showStatus(ctx: Context, session: Relay.Session) {
        ensureChannel(ctx)
        val what = ctx.getString(
            when (session.state) {
                "error" -> R.string.notif_error
                "question" -> R.string.notif_question
                "ratelimit" -> R.string.notif_ratelimit
                else -> R.string.notif_finished
            },
        )
        val n = NotificationCompat.Builder(ctx, CHANNEL_UPDATES)
            .setSmallIcon(R.drawable.ic_stat_coucou)
            .setContentTitle(session.agent)
            .setContentText(what)
            .setSubText(session.statusText.takeIf { it.isNotBlank() })
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(
                NotificationCompat.Builder(ctx, CHANNEL_UPDATES)
                    .setSmallIcon(R.drawable.ic_stat_coucou)
                    .setContentTitle(ctx.getString(R.string.app_name))
                    .setContentText(what)
                    .build(),
            )
            .setAutoCancel(true)
            .build()
        runCatching { NotificationManagerCompat.from(ctx).notify(session.pillId, STATUS_ID, n) }
    }

    /**
     * The always-there line: which agents are busy and how many are waiting.
     * Silent (IMPORTANCE_MIN), ongoing, and on Android 16+ promoted so it shows
     * as the Live Update chip in the status bar. Nothing private in it — the
     * command text never leaves the loud card.
     */
    fun updateLive(ctx: Context, sessions: List<Relay.Session>) {
        if (sessions.isEmpty()) {
            cancelLive(ctx)
            return
        }
        ensureChannel(ctx)
        val needs = sessions.count { it.state == "approval" || it.state == "question" }
        val running = sessions.count { it.state == "working" || it.state == "thinking" || it.state == "searching" }
        val text = when {
            needs > 0 -> ctx.resources.getQuantityString(R.plurals.live_needs, needs, needs)
            running > 0 -> ctx.resources.getQuantityString(R.plurals.live_running, running, running)
            else -> ctx.getString(R.string.live_quiet)
        }
        val style = NotificationCompat.InboxStyle()
        sessions.sortedByDescending { urgencyOf(it.state) }.take(5).forEach { s ->
            style.addLine("${s.agent} · ${s.statusText.ifBlank { s.state }}")
        }
        val open = PendingIntent.getActivity(
            ctx, 0,
            ctx.packageManager.getLaunchIntentForPackage(ctx.packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val n = NotificationCompat.Builder(ctx, CHANNEL_LIVE)
            .setSmallIcon(R.drawable.ic_stat_coucou)
            .setContentTitle(ctx.getString(R.string.app_name))
            .setContentText(text)
            .setStyle(style)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .build()
        // Live Update chip on the status bar (API 36+); harmless flag elsewhere.
        if (Build.VERSION.SDK_INT >= 36) {
            @Suppress("WrongConstant")
            n.flags = n.flags or Notification.FLAG_PROMOTED_ONGOING
        }
        runCatching { NotificationManagerCompat.from(ctx).notify(LIVE_ID, n) }
    }

    fun cancelLive(ctx: Context) {
        runCatching { NotificationManagerCompat.from(ctx).cancel(LIVE_ID) }
    }

    fun cancelCard(ctx: Context) = cancelAllCards(ctx)

    fun cancelCard(ctx: Context, requestId: String) {
        NotificationManagerCompat.from(ctx).cancel(requestId, CARD_ID)
    }

    /** Nothing waits any more — every request's card goes, not just the last. */
    fun cancelAllCards(ctx: Context) {
        runCatching {
            val nm = ctx.getSystemService(NotificationManager::class.java)
            nm.activeNotifications
                .filter { it.notification.channelId == CHANNEL }
                .forEach { nm.cancel(it.tag, it.id) }
        }
    }

    /** Coucou is on screen: the notices are redundant. */
    fun cancelAllStatus(ctx: Context) {
        runCatching {
            val nm = ctx.getSystemService(NotificationManager::class.java)
            nm.activeNotifications
                .filter { it.notification.channelId == CHANNEL_UPDATES }
                .forEach { nm.cancel(it.tag, it.id) }
        }
    }
}
