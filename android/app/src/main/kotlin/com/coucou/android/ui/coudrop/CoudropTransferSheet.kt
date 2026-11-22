package com.coucou.android.ui.coudrop

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.coucou.android.core.TypeScale
import com.coucou.android.drop.ActiveTransferUiState
import com.coucou.android.drop.TransferDirection
import com.coucou.android.ui.PillButton
import com.coucou.android.ui.PillKind
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

@Composable
fun CoudropTransferCard(
    state: ActiveTransferUiState,
    onCancel: (String) -> Unit,
    onPause: ((String) -> Unit)? = null,
    onResume: ((String) -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val t = tokens()
    val record = state.record
    val pct = (state.progress * 100).toInt().coerceIn(0, 100)
    val isSending = record.direction == TransferDirection.OUTGOING
    val isPaused = state.isPaused || record.status == com.coucou.android.drop.TransferStatus.PAUSED
    val speedText = if (!isPaused && state.speedMBps > 0.05) " • %.1f MB/s".format(state.speedMBps) else if (isPaused) " • Paused" else ""

    Box(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(t.panel.c())
            .border(1.dp, t.line.c(), RoundedCornerShape(16.dp))
            .padding(16.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = if (isPaused) "Paused · ${record.name}" else if (isSending) "Sending ${record.name}" else "Receiving ${record.name}",
                    style = TypeScale.BODY.style(t.text.c()).copy(fontWeight = FontWeight.SemiBold),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    text = "$pct%",
                    style = TypeScale.BODY.style(t.text.c()).copy(fontWeight = FontWeight.Bold),
                    modifier = Modifier.padding(start = 8.dp),
                )
            }

            LinearProgressIndicator(
                progress = { state.progress },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(6.dp)
                    .clip(CircleShape),
                color = if (isPaused) StatusColors.busy else StatusColors.online,
                trackColor = t.secondaryButton.c(),
            )

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                val transferredBytes = (state.progress * record.size).toLong()
                Text(
                    text = "${formatBytes(transferredBytes)} / ${formatBytes(record.size)}$speedText",
                    style = TypeScale.SECONDARY.style(t.textDim.c()),
                )

                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (isPaused) {
                        if (onResume != null) {
                            PillButton(
                                text = "Resume",
                                onClick = { onResume(record.id) },
                                kind = PillKind.SECONDARY,
                            )
                        }
                    } else {
                        if (onPause != null) {
                            PillButton(
                                text = "Pause",
                                onClick = { onPause(record.id) },
                                kind = PillKind.SECONDARY,
                            )
                        }
                    }
                    PillButton(
                        text = "Cancel",
                        onClick = { onCancel(record.id) },
                        kind = PillKind.DANGER,
                    )
                }
            }
        }
    }
}
