package com.coucou.android.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.coucou.android.R
import com.coucou.android.app.AppModel
import com.coucou.android.core.IconKind
import com.coucou.android.core.Spacing
import com.coucou.android.core.TypeScale
import com.coucou.android.link.BatteryHint
import com.coucou.android.link.LinkHealthText
import com.coucou.android.link.LinkState
import kotlinx.coroutines.delay

/**
 * Shown on Home while the link is down after having worked: what happened and how long ago ("Connection lost 2 min ago,
 * reconnecting"), why in one sentence, and the way to "Can't connect?". The time is refreshed while this is on screen, never in the background.
 */
@Composable
fun LinkHealthPanel(model: AppModel, onHelp: () -> Unit) {
    val now by produceState(System.currentTimeMillis()) {
        while (true) {
            delay(15_000)
            value = System.currentTimeMillis()
        }
    }
    val lines = LinkHealthText.lines(model.linkState == LinkState.CONNECTED, model.health, now, model.wifiUp) ?: return
    val t = tokens()

    Panel {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(Spacing.INSIDE.dp),
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Box(
                modifier = Modifier
                    .size(36.dp)
                    .clip(CircleShape)
                    .background(t.danger.c().copy(alpha = 0.15f)),
                contentAlignment = Alignment.Center,
            ) {
                StateDot(t.danger.c())
            }

            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text(
                    lines.first,
                    style = TypeScale.BODY.style(t.text.c()).copy(fontWeight = FontWeight.SemiBold),
                )
                if (lines.second.isNotEmpty()) {
                    Text(
                        lines.second,
                        style = TypeScale.SECONDARY.style(t.textDim.c()),
                    )
                }
            }
        }
        RowDivider(startIndent = 16.dp)
        ListRow(
            stringResource(R.string.diag_title),
            onClick = onHelp,
            trailing = { CoucouIcon(IconKind.CHEVRON, tint = t.textDim.c(), size = 18.dp) },
        )
    }
}

/**
 * A calm suggestion, shown only when the link ended on its own after the screen had been off and Android still restricts the app. It
 * opens Android's own screen (the app cannot change the setting by itself) and says where it is on Samsung phones.
 */
@Composable
fun BatteryCard(model: AppModel) {
    val context = LocalContext.current
    val t = tokens()
    Panel {
        Column(Modifier.padding(Spacing.INSIDE.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(stringResource(R.string.battery_title), style = TypeScale.HEADLINE.style(t.text.c()))
            Text(stringResource(R.string.battery_body), style = TypeScale.SECONDARY.style(t.textDim.c()))
            model.batterySteps.forEachIndexed { i, step ->
                Row(
                    modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.Top,
                ) {
                    Box(
                        modifier = Modifier
                            .size(20.dp)
                            .clip(CircleShape)
                            .background(t.panel2.c()),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text("${i + 1}", style = TypeScale.LABEL.style(t.textDim.c()))
                    }
                    Text(step, style = TypeScale.SECONDARY.style(t.text.c()), modifier = Modifier.weight(1f))
                }
            }
            Row(Modifier.fillMaxWidth().padding(top = 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                PillButton(stringResource(R.string.battery_not_now), { model.snoozeBatteryHint() }, Modifier.weight(1f))
                PillButton(stringResource(R.string.battery_open), { openBatterySettings(context) }, Modifier.weight(1f), PillKind.PRIMARY)
            }
        }
    }
}

/** Samsung's own steps start in the app's page; elsewhere the list of battery-optimised apps is the direct way. */
private fun openBatterySettings(context: Context) {
    val details = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}"))
    val list = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
    val order = if (BatteryHint.isSamsung(android.os.Build.MANUFACTURER)) listOf(details, list) else listOf(list, details)
    for (intent in order) {
        if (runCatching { context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }.isSuccess) return
    }
}
