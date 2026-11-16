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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.coucou.android.core.IconKind
import com.coucou.android.drop.CoudropRecord
import com.coucou.android.drop.TransferDirection
import com.coucou.android.drop.TransferStatus
import com.coucou.android.ui.CoucouIcon

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
    val context = LocalContext.current
    val isIncoming = record.direction == TransferDirection.INCOMING
    val isSuccess = record.status == TransferStatus.COMPLETED

    Box(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(Color(0xFF16181B))
            .border(1.dp, Color(0xFF24272E), RoundedCornerShape(12.dp))
            .clickable { openFile(context, record) }
            .padding(horizontal = 12.dp, vertical = 10.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // Status Icon Badge
            Box(
                modifier = Modifier
                    .size(32.dp)
                    .clip(CircleShape)
                    .background(
                        if (isSuccess) Color(0xFF30D158).copy(alpha = 0.16f)
                        else Color(0xFFFF453A).copy(alpha = 0.16f),
                    ),
                contentAlignment = Alignment.Center,
            ) {
                CoucouIcon(
                    kind = if (isSuccess) IconKind.CHECK else IconKind.CLOSE,
                    tint = if (isSuccess) Color(0xFF30D158) else Color(0xFFFF453A),
                    size = 16.dp,
                )
            }

            // Filename and Direction Details
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = record.name,
                    color = Color.White,
                    fontWeight = FontWeight.Medium,
                    fontSize = 13.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = "${if (isIncoming) "Received" else "Sent"} • ${formatBytes(record.size)}",
                    color = Color(0xFF8E8E93),
                    fontSize = 11.sp,
                )
            }

            // Open indicator
            CoucouIcon(
                kind = IconKind.CHEVRON,
                tint = Color(0xFF48484A),
                size = 16.dp,
            )
        }
    }
}
