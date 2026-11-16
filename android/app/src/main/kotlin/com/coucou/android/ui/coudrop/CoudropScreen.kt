package com.coucou.android.ui.coudrop

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.coucou.android.app.AppModel
import com.coucou.android.core.IconKind
import com.coucou.android.link.LinkState
import com.coucou.android.ui.CoucouIcon
import com.coucou.android.ui.Gutter
import com.coucou.android.ui.PillButton
import com.coucou.android.ui.PillKind
import com.coucou.android.ui.tokens

@Composable
fun CoudropScreen(
    model: AppModel,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val t = tokens()
    val isConnected = model.linkState == LinkState.CONNECTED
    val desktopName = model.desktopName ?: "Computer"
    val activeTransfers by model.coudropManager.activeTransfers.collectAsState()
    val history by model.coudropManager.history.collectAsState()

    // Pickers
    val filePicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        if (uris.isNotEmpty()) {
            model.coudropManager.sendUris(uris)
        }
    }

    val photoPicker = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia()) { uris ->
        if (uris.isNotEmpty()) {
            model.coudropManager.sendUris(uris)
        }
    }

    LazyColumn(
        modifier = modifier
            .fillMaxSize()
            .background(Color(0xFF0F1012)),
        contentPadding = PaddingValues(horizontal = Gutter, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        // Top App Bar
        item {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Box(
                    modifier = Modifier
                        .size(36.dp)
                        .clip(CircleShape)
                        .background(Color(0xFF1E2024))
                        .clickable(onClick = onBack),
                    contentAlignment = Alignment.Center,
                ) {
                    CoucouIcon(kind = IconKind.BACK, tint = Color.White, size = 18.dp)
                }

                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = "Coudrop",
                        color = Color.White,
                        fontWeight = FontWeight.Bold,
                        fontSize = 18.sp,
                    )
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Box(
                            modifier = Modifier
                                .size(6.dp)
                                .clip(CircleShape)
                                .background(if (isConnected) Color(0xFF30D158) else Color(0xFF8E8E93)),
                        )
                        Text(
                            text = if (isConnected) "Connected to $desktopName" else "Computer offline",
                            color = Color(0xFF8E8E93),
                            fontSize = 11.sp,
                        )
                    }
                }
            }
        }

        // Radar Section
        item {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(20.dp))
                    .background(Color(0xFF16181B))
                    .border(1.dp, Color(0xFF24272E), RoundedCornerShape(20.dp))
                    .padding(vertical = 24.dp),
                contentAlignment = Alignment.Center,
            ) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    CoudropRadarView(linkState = model.linkState)

                    Text(
                        text = if (isConnected) "Quick Share with $desktopName" else "Open Coucou on your computer",
                        color = Color.White,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 15.sp,
                    )
                    Text(
                        text = "Instant, zero-cloud peer-to-peer TLS transfer",
                        color = Color(0xFF8E8E93),
                        fontSize = 11.sp,
                    )

                    // Action buttons
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                        modifier = Modifier.padding(top = 4.dp),
                    ) {
                        PillButton(
                            text = "Send files",
                            onClick = { filePicker.launch(arrayOf("*/*")) },
                            kind = PillKind.PRIMARY,
                            enabled = isConnected,
                        )
                        PillButton(
                            text = "Photos & Videos",
                            onClick = {
                                photoPicker.launch(
                                    PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo),
                                )
                            },
                            kind = PillKind.SECONDARY,
                            enabled = isConnected,
                        )
                    }
                }
            }
        }

        // Active Transfers
        if (activeTransfers.isNotEmpty()) {
            item {
                Text(
                    text = "ACTIVE TRANSFERS",
                    color = Color(0xFF8E8E93),
                    fontWeight = FontWeight.Bold,
                    fontSize = 10.sp,
                    letterSpacing = 1.sp,
                    modifier = Modifier.padding(start = 4.dp),
                )
            }
            items(activeTransfers.values.toList(), key = { it.record.id }) { activeState ->
                CoudropTransferCard(
                    state = activeState,
                    onCancel = { model.coudropManager.cancel(it) },
                )
            }
        }

        // Recent Transfers History
        item {
            Row(
                modifier = Modifier.fillMaxWidth().padding(start = 4.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = "RECENT TRANSFERS",
                    color = Color(0xFF8E8E93),
                    fontWeight = FontWeight.Bold,
                    fontSize = 10.sp,
                    letterSpacing = 1.sp,
                )
                if (history.isNotEmpty()) {
                    Text(
                        text = "Clear",
                        color = Color(0xFF0A84FF),
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Medium,
                        modifier = Modifier
                            .clickable { model.coudropManager.clearHistory() }
                            .padding(4.dp),
                    )
                }
            }
        }

        if (history.isEmpty()) {
            item {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 20.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = "Transferred files will appear here",
                        color = Color(0xFF48484A),
                        fontSize = 12.sp,
                    )
                }
            }
        } else {
            items(history, key = { it.id }) { record ->
                CoudropHistoryItem(record = record)
            }
        }

        item { Spacer(Modifier.height(32.dp)) }
    }
}
