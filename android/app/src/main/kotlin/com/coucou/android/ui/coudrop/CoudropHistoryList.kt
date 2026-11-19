package com.coucou.android.ui.coudrop

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.coucou.android.core.IconKind
import com.coucou.android.core.TypeScale
import com.coucou.android.drop.CoudropRecord
import com.coucou.android.drop.TransferDirection
import com.coucou.android.drop.TransferStatus
import com.coucou.android.ui.CoucouIcon
import com.coucou.android.ui.StatusColors
import com.coucou.android.ui.c
import com.coucou.android.ui.style
import com.coucou.android.ui.tokens

private fun formatBytes(bytes: Long): String {
    return when {
        bytes < 1024 -> "$bytes B"
        bytes < 1024 * 1024 -> "${bytes / 1024} KB"
        else -> "%.1f MB".format(bytes / (1024.0 * 1024.0))
    }
}

private fun openFile(context: Context, record: CoudropRecord) {
    val uriStr = record.uriString ?: return
    runCatching {
        val uri = Uri.parse(uriStr)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, record.mimeType)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(intent)
    }
}

@Composable
fun CoudropHistoryItem(
    record: CoudropRecord,
    modifier: Modifier = Modifier,
) {
    val t = tokens()
    val context = LocalContext.current
    val isIncoming = record.direction == TransferDirection.INCOMING
    val isSuccess = record.status == TransferStatus.COMPLETED
    val statusTint = if (isSuccess) StatusColors.online else t.danger.c()

    Box(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(t.panel.c())
            .border(1.dp, t.line.c(), RoundedCornerShape(14.dp))
            .clickable { openFile(context, record) }
            .padding(horizontal = 14.dp, vertical = 12.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // Status Icon Badge
            Box(
                modifier = Modifier
                    .size(34.dp)
                    .clip(CircleShape)
                    .background(statusTint.copy(alpha = 0.16f)),
                contentAlignment = Alignment.Center,
            ) {
                CoucouIcon(
                    kind = if (isSuccess) IconKind.CHECK else IconKind.CLOSE,
                    tint = statusTint,
                    size = 16.dp,
                )
            }

            // Filename and Direction Details
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    text = record.name,
                    style = TypeScale.BODY.style(t.text.c()).copy(fontWeight = FontWeight.Medium),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = "${if (isIncoming) "Received" else "Sent"} • ${formatBytes(record.size)}",
                    style = TypeScale.SECONDARY.style(t.textDim.c()),
                )
            }

            // Open indicator
            CoucouIcon(
                kind = IconKind.CHEVRON,
                tint = t.textDim.c(),
                size = 16.dp,
            )
        }
    }
}
