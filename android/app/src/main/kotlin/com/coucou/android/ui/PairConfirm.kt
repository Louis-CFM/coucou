package com.coucou.android.ui

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import com.coucou.android.R
import com.coucou.android.app.AppModel
import com.coucou.android.link.PairingPayload

/**
 * Asked before a scanned code, or a link opened from the camera app, pairs anything. It names the computer and
 * its address on the network (and the relay's host when the link has one), never a secret in the link, and says when it replaces the current computer.
 */
@Composable
fun PairConfirm(model: AppModel, link: String) {
    val p = PairingPayload.parse(link)
    if (p == null) { model.cancelPairing(); return }
    AlertDialog(
        onDismissRequest = { model.cancelPairing() },
        title = { Text(stringResource(R.string.pair_confirm_title, p.desktopName.ifBlank { p.host })) },
        text = {
            Text(
                stringResource(R.string.pair_confirm_body, p.host, p.port) +
                    // The relay's host is shown too: a code that points somewhere else is visible before anything is stored.
                    (p.relay?.relayUrl()?.host?.let { "\n\n" + stringResource(R.string.pair_confirm_relay, it) } ?: "") +
                    if (model.isPaired) "\n\n" + stringResource(R.string.pair_confirm_replace) else "",
                style = MaterialTheme.typography.bodyMedium,
            )
        },
        confirmButton = { TextButton(onClick = { model.confirmPairing() }) { Text(stringResource(R.string.pair_confirm_ok)) } },
        dismissButton = { TextButton(onClick = { model.cancelPairing() }) { Text(stringResource(R.string.action_cancel)) } },
    )
}
