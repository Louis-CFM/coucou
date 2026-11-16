package com.coucou.android.drop

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import com.coucou.android.MainActivity
import com.coucou.android.R

/**
 * Manages notifications for Vayli Drop file transfers.
 */
class TransferNotificationManager(private val context: Context) {
    private val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    init {
        createChannel()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Vayli Drop",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "File transfers with your computer"
                setShowBadge(true)
            }
            nm.createNotificationChannel(channel)
        }
    }

    private fun formatBytes(bytes: Long): String {
        return when {
            bytes < 1024 -> "$bytes B"
            bytes < 1024 * 1024 -> "${bytes / 1024} KB"
            else -> "%.1f MB".format(bytes / (1024.0 * 1024.0))
        }
    }

    fun showProgress(transferId: String, fileName: String, bytesReceived: Long, totalBytes: Long) {
        val notifId = transferId.hashCode()
        val pct = if (totalBytes > 0) ((bytesReceived * 100) / totalBytes).toInt().coerceIn(0, 100) else 0

        val contentIntent = PendingIntent.getActivity(
            context,
            notifId,
            Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }

        builder.setContentTitle("Receiving $fileName")
            .setContentText("$pct% (${formatBytes(bytesReceived)} / ${formatBytes(totalBytes)})")
            .setSmallIcon(R.drawable.ic_stat_mochi)
            .setProgress(100, pct, false)
            .setOngoing(true)
            .setAutoCancel(false)
            .setContentIntent(contentIntent)

        nm.notify(notifId, builder.build())
    }

    fun showComplete(transferId: String, fileName: String, totalBytes: Long, fileUri: Uri?, mimeType: String = "*/*") {
        val notifId = transferId.hashCode()

        val viewIntent = if (fileUri != null) {
            Intent(Intent.ACTION_VIEW).apply {
                val resolvedMime = if (mimeType.isNotBlank() && mimeType != "application/octet-stream") mimeType else "*/*"
                setDataAndType(fileUri, resolvedMime)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        } else {
            Intent(context, MainActivity::class.java)
        }

        val contentIntent = PendingIntent.getActivity(
            context,
            notifId,
            viewIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }

        builder.setContentTitle("File received")
            .setContentText("$fileName (${formatBytes(totalBytes)})")
            .setSmallIcon(R.drawable.ic_stat_mochi)
            .setProgress(0, 0, false)
            .setOngoing(false)
            .setAutoCancel(true)
            .setContentIntent(contentIntent)

        nm.notify(notifId, builder.build())
    }

    fun dismiss(transferId: String) {
        nm.cancel(transferId.hashCode())
    }

    companion object {
        const val CHANNEL_ID = "coucou_vayli_drop"
    }
}
