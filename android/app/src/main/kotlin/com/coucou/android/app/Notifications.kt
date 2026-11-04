package com.coucou.android.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.net.Uri
import android.util.Log
import com.coucou.android.MainActivity
import com.coucou.android.R
import com.coucou.android.core.ApprovalChannels
import com.coucou.android.core.ApprovalSheetPlan
import com.coucou.android.core.Glance
import com.coucou.android.core.GlanceTone
import com.coucou.android.core.OverlayPolicy
import com.coucou.android.core.OngoingGate
import com.coucou.android.core.SafeText
import com.coucou.android.core.ToolLabels
import com.coucou.android.core.VibrationChoice
import com.coucou.android.link.ApprovalRequest
import com.coucou.android.mochi.BotState

/**
 * Notifications: one quiet ongoing notification for the link, and a loud one per approval.
 * Deny acts straight from the notification. Allow always opens the app for the biometric
 * check first, and the command is hidden on the lock screen.
 */
class Notifications(private val context: Context) {
    private val nm = context.getSystemService(NotificationManager::class.java)

    init {
        nm.deleteNotificationChannel("approvals")
        nm.deleteNotificationChannel("approvals_v2")
        createChannels()
    }

    /** The channels' names and descriptions are in the app's language (Android shows them in its own settings); made again when it changes. */
    private fun createChannels() {
        nm.createNotificationChannel(
            NotificationChannel(CH_LINK, context.getString(R.string.channel_link), NotificationManager.IMPORTANCE_LOW).apply {
                description = context.getString(R.string.channel_link_description)
                setShowBadge(false)
            },
        )
        nm.createNotificationChannel(
            NotificationChannel(CH_UPDATES, context.getString(R.string.channel_updates), NotificationManager.IMPORTANCE_LOW).apply {
                description = context.getString(R.string.channel_updates_description)
                setShowBadge(false)
            },
        )
        // The same request while the pill is on screen: in the shade only, no heads-up and no sound,
        // so the pill and the notification never overlap at the top of the screen.
        nm.createNotificationChannel(
            NotificationChannel(CH_APPROVAL_QUIET, context.getString(R.string.channel_approvals_quiet), NotificationManager.IMPORTANCE_LOW).apply {
                description = context.getString(R.string.channel_approvals_quiet_description)
                setShowBadge(false)
            },
        )
        // The approvals channel is made by applyApprovalSettings (its id depends on the vibration choice).
    }

    private var vibration = VibrationChoice.STANDARD
    private var keepScreenOff = false
    private var channelFor: VibrationChoice? = null

    /**
     * The two Settings choices about a request: how it buzzes and whether it lights the screen. A channel's vibration cannot change
     * after it exists, so a new choice means a new channel id and the old channel is deleted. The channel stays IMPORTANCE_HIGH with
     * Mochi's sound whatever is chosen: a request is never muted or hidden.
     */
    fun applyApprovalSettings(v: VibrationChoice, screenOff: Boolean) {
        keepScreenOff = screenOff
        if (channelFor == v) return // the channel exists already: nothing to rebuild when another setting moves
        channelFor = v
        vibration = v
        ApprovalChannels.othersThan(v).forEach { nm.deleteNotificationChannel(it) }
        nm.createNotificationChannel(
            NotificationChannel(ApprovalChannels.id(v), context.getString(R.string.channel_approvals), NotificationManager.IMPORTANCE_HIGH).apply {
                description = context.getString(R.string.channel_approvals_description)
                val pattern = v.pattern
                if (pattern != null) {
                    enableVibration(true)
                    vibrationPattern = pattern
                } else {
                    enableVibration(false)
                }
                // Mochi's own approval sound, bundled in res/raw.
                setSound(
                    Uri.parse("${ContentResolver.SCHEME_ANDROID_RESOURCE}://${context.packageName}/${R.raw.approval}"),
                    AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION).build(),
                )
            },
        )
    }

    private fun open(fp: String?, allow: Boolean, code: Int): PendingIntent {
        // A request goes through LaunchActivity (not exported); a plain open needs no extras and goes straight to the app.
        val i = Intent(context, if (fp != null) LaunchActivity::class.java else MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            .apply { if (fp != null) { putExtra(EXTRA_FP, fp); putExtra(EXTRA_ALLOW, allow) } }
        return PendingIntent.getActivity(context, code, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    /**
     * The quiet notification that keeps the link alive: the headline of [Glance] as its title, the detail under it and,
     * when expanded, one line per agent ("Claude Code: Working"). Only states, never a command or a path. On a locked
     * screen it shows the plain "Connected" line, like the other notifications of the app.
     */
    fun ongoing(model: AppModel?): Notification {
        val g = model?.glance()
        ongoingGate.forget()
        ongoingGate.shouldPost(g) // what the service posts is now the last notification
        return ongoing(g)
    }

    private fun ongoing(g: Glance?): Notification {
        val title = g?.headline ?: context.getString(R.string.status_connecting)
        val detail = g?.detail.orEmpty()
        val b = Notification.Builder(context, CH_LINK)
            .setSmallIcon(R.drawable.ic_stat_mochi)
            .setContentTitle(title)
            .setContentText(detail)
            .setColor(g?.tone?.argb ?: GlanceTone.CALM.argb)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setPublicVersion(
                Notification.Builder(context, CH_LINK).setSmallIcon(R.drawable.ic_stat_mochi)
                    .setContentTitle(context.getString(R.string.app_name))
                    .setContentText(if (g?.connected == true) context.getString(R.string.status_connected) else context.getString(R.string.status_not_connected))
                    .build(),
            )
            .setContentIntent(open(null, false, 0))
        if (g != null && g.lines.isNotEmpty()) {
            b.setStyle(Notification.BigTextStyle().bigText(g.lines.joinToString("\n") { "${it.agent}: ${it.text}" }).setSummaryText(detail))
        }
        return b.build()
    }

    /** The language changed: the next push posts the ongoing notification again, whatever it said before, and the channels get their new names. */
    fun forgetOngoing() {
        ongoingGate.forget()
        createChannels()
        channelFor = null
        applyApprovalSettings(vibration, keepScreenOff)
    }

    /** Only posted again when what it shows changes ([OngoingGate]); the service's own first post counts as the last one. */
    private val ongoingGate = OngoingGate()

    fun updateOngoing(model: AppModel, g: Glance = model.glance()) {
        if (model.mode == Mode.PAIRED && ongoingGate.shouldPost(g)) runCatching { nm.notify(ONGOING_ID, ongoing(g)) }
    }

    fun showApproval(r: ApprovalRequest, agentName: String, alert: OverlayPolicy.ApprovalAlert = OverlayPolicy.ApprovalAlert.HEADS_UP) {
        val channel = if (alert == OverlayPolicy.ApprovalAlert.QUIET) CH_APPROVAL_QUIET else ApprovalChannels.id(vibration)
        Log.d("CoucouOverlay", "approval notification: $alert")
        val id = idFor(r.fingerprint)
        val deny = PendingIntent.getBroadcast(
            context, id, Intent(context, ActionReceiver::class.java).setAction(ACTION_DENY).putExtra(EXTRA_FP, r.fingerprint),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val publicVersion = Notification.Builder(context, channel)
            .setSmallIcon(R.drawable.ic_stat_mochi).setContentTitle(context.getString(R.string.approval_title)).setContentText(context.getString(R.string.notif_unlock)).build()
        val n = Notification.Builder(context, channel)
            .setSmallIcon(R.drawable.ic_stat_mochi)
            .setContentTitle(agentName)
            .setSubText(context.getString(R.string.approval_title))
            // A label and at most the program's name: the exact command is on the approval sheet, behind a tap.
            .setContentText(SafeText.requestLabel(r.tool, r.command))
            .setCategory(Notification.CATEGORY_ALARM)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setPublicVersion(publicVersion)
            .setAutoCancel(true)
            .setTimeoutAfter(com.coucou.android.link.Protocol.APPROVAL_TTL_MS)
            .setContentIntent(open(r.fingerprint, false, id))
            .addAction(Notification.Action.Builder(null, context.getString(R.string.action_deny), deny).build())
            .apply {
                // A command the phone cannot show in full is answered on the computer: no Allow here.
                if (ApprovalSheetPlan.canAllowHere(r)) addAction(Notification.Action.Builder(null, context.getString(R.string.action_allow), open(r.fingerprint, true, id + 1)).build())
            }
            .build()
        runCatching { nm.notify(id, n) } // POST_NOTIFICATIONS may be denied: the in-app card still works
        if (alert == OverlayPolicy.ApprovalAlert.HEADS_UP && !keepScreenOff) wakeScreen()
    }

    /**
     * A request on a sleeping phone lights the screen for a few seconds, so the lock screen shows the notification
     * ("Unlock to see the request"). The phone stays locked; nothing about the command is shown.
     */
    @Suppress("DEPRECATION")
    private fun wakeScreen() = runCatching {
        val pm = context.getSystemService(android.os.PowerManager::class.java)
        if (pm.isInteractive) return@runCatching
        pm.newWakeLock(android.os.PowerManager.SCREEN_BRIGHT_WAKE_LOCK or android.os.PowerManager.ACQUIRE_CAUSES_WAKEUP, "coucou:approval")
            .acquire(WAKE_MS)
    }

    fun cancelApproval(fp: String) = nm.cancel(idFor(fp))

    /** An agent finished, failed, hit a limit or asks something. Quiet: Mochi's own sound and the pill are the alerts. */
    fun showStatus(pillId: String, agentName: String, state: BotState, statusText: String) {
        val what = context.getString(
            when (state) {
                BotState.ERROR -> R.string.notif_error
                BotState.QUESTION -> R.string.notif_question
                BotState.RATELIMIT -> R.string.notif_ratelimit
                else -> R.string.notif_finished
            },
        )
        val n = Notification.Builder(context, CH_UPDATES)
            .setSmallIcon(R.drawable.ic_stat_mochi)
            .setContentTitle(agentName)
            .setContentText(what)
            .setSubText(ToolLabels.label(statusText).takeIf { it.isNotBlank() })
            .setCategory(Notification.CATEGORY_STATUS)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setPublicVersion(
                Notification.Builder(context, CH_UPDATES).setSmallIcon(R.drawable.ic_stat_mochi)
                    .setContentTitle(context.getString(R.string.app_name)).setContentText(what).build(),
            )
            .setAutoCancel(true)
            .setContentIntent(open(null, false, 0))
            .build()
        runCatching { nm.notify(STATUS_TAG, statusId(pillId), n) }
    }

    fun cancelStatus(pillId: String) = runCatching { nm.cancel(STATUS_TAG, statusId(pillId)) }

    /** Coucou is on screen: the notices are redundant. */
    fun cancelAllStatus() {
        runCatching { nm.activeNotifications.filter { it.tag == STATUS_TAG }.forEach { nm.cancel(it.tag, it.id) } }
    }

    private fun statusId(pillId: String) = pillId.hashCode() and 0x3fffffff

    /** Opens the app on the biometric prompt for this request (the same as tapping Allow in the notification). */
    fun openAllow(fp: String) {
        Log.d("CoucouLaunch", "open the app on Allow (tap on the pill)")
        runCatching { open(fp, true, idFor(fp) + 1).send() }
    }

    fun openApp() {
        Log.d("CoucouLaunch", "open the app (tap on the pill)")
        runCatching { open(null, false, 0).send() }
    }

    companion object {
        const val CH_LINK = "link"
        private const val WAKE_MS = 6_000L
        const val CH_APPROVAL_QUIET = "approvals_quiet"
        const val CH_UPDATES = "updates"
        private const val STATUS_TAG = "status"
        const val ONGOING_ID = 1
        const val ACTION_DENY = "com.coucou.android.DENY"
        const val EXTRA_FP = "fingerprint"
        const val EXTRA_ALLOW = "allow"
        /** Even ids for the request, +1 for its Allow action; never collides with ONGOING_ID. */
        fun idFor(fp: String) = (fp.hashCode() and 0x3fffffff) * 2 + 2
    }
}

/** Handles the Deny button. Denying needs no biometric check: it can only make things safer. */
class ActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Notifications.ACTION_DENY) return
        val fp = intent.getStringExtra(Notifications.EXTRA_FP) ?: return
        (context.applicationContext as CoucouApp).model.decide(fp, allow = false)
    }
}
