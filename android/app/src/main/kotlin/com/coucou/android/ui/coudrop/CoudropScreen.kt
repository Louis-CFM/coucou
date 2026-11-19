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
import com.coucou.android.core.TypeScale
import com.coucou.android.link.LinkState
import com.coucou.android.ui.CoucouIcon
import com.coucou.android.ui.Gutter
import com.coucou.android.ui.Panel
import com.coucou.android.ui.PillButton
import com.coucou.android.ui.PillKind
import com.coucou.android.ui.SectionHeading
import com.coucou.android.ui.StateDot
import com.coucou.android.ui.StatusColors
import com.coucou.android.ui.c
import com.coucou.android.ui.style
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
            .background(t.bg.c()),
        contentPadding = PaddingValues(horizontal = Gutter, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        // Top App Bar
        item {
            Row(
                modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Box(
                    modifier = Modifier
                        .size(38.dp)
                        .clip(CircleShape)
                        .background(t.panel2.c())
                        .clickable(onClick = onBack),
                    contentAlignment = Alignment.Center,
                ) {
                    CoucouIcon(kind = IconKind.BACK, tint = t.text.c(), size = 18.dp)
                }

                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = "Coudrop",
                        color = t.text.c(),
                        fontWeight = FontWeight.Bold,
                        fontSize = 20.sp,
                        letterSpacing = (-0.3).sp,
                    )
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        StateDot(if (isConnected) StatusColors.online else StatusColors.offline)
                        Text(
                            text = if (isConnected) "Connected to $desktopName" else "Computer offline",
                            style = TypeScale.SECONDARY.style(t.textDim.c()),
                        )
                    }
                }
            }
        }

        // Radar Section
        item {
            Panel {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 24.dp, horizontal = 16.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    CoudropRadarView(linkState = model.linkState)

                    Text(
                        text = if (isConnected) "Quick Share with $desktopName" else "Open Coucou on your computer",
                        style = TypeScale.HEADLINE.style(t.text.c()).copy(fontWeight = FontWeight.SemiBold),
                    )
                    Text(
                        text = "Instant, zero-cloud peer-to-peer TLS transfer",
                        style = TypeScale.SECONDARY.style(t.textDim.c()),
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
                SectionHeading("ACTIVE TRANSFERS")
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
                modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                SectionHeading("RECENT TRANSFERS")
                if (history.isNotEmpty()) {
                    Text(
                        text = "Clear",
                        style = TypeScale.LABEL.style(t.textDim.c()).copy(fontWeight = FontWeight.SemiBold),
                        modifier = Modifier
                            .clickable { model.coudropManager.clearHistory() }
                            .padding(horizontal = 8.dp, vertical = 4.dp),
                    )
                }
            }
        }

        if (history.isEmpty()) {
            item {
                Panel {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 24.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            text = "Transferred files will appear here",
                            style = TypeScale.SECONDARY.style(t.textDim.c()),
                        )
                    }
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
