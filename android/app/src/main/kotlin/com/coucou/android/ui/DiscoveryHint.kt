package com.coucou.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.coucou.android.R
import com.coucou.android.app.AppModel
import com.coucou.android.core.IslandSurface
import com.coucou.android.core.Spacing
import com.coucou.android.core.Tokens
import com.coucou.android.core.TypeScale

/**
 * Shown on Home when the saved address failed and a search of about 15 seconds found nothing. Calm, with the usual
 * reasons (same Wi-Fi? asleep? firewall? client isolation) and two ways out: pair again, or type the address.
 */
@Composable
fun DiscoveryHint(onPairAgain: () -> Unit, onEnterAddress: () -> Unit) {
    val t = tokens()
    Panel {
        Column(Modifier.padding(Spacing.INSIDE.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(stringResource(R.string.discovery_title), style = TypeScale.HEADLINE.style(t.text.c()))
            Text(stringResource(R.string.discovery_body), style = TypeScale.SECONDARY.style(t.textDim.c()))
            Row(Modifier.fillMaxWidth().padding(top = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                PillButton(stringResource(R.string.discovery_pair_again), onPairAgain, Modifier.weight(1f))
                PillButton(stringResource(R.string.discovery_enter_address), onEnterAddress, Modifier.weight(1f))
            }
        }
    }
}

/** The computer's address typed by hand ("192.168.1.20" or "192.168.1.20:47821"). Only the address changes: the pairing and the certificate stay. */
@Composable
fun AddressSheet(model: AppModel, onDismiss: () -> Unit) {
    var text by remember { mutableStateOf("") }
    var bad by remember { mutableStateOf(false) }
    val white = Color(IslandSurface.TEXT)
    val dim = Color(IslandSurface.TEXT_DIM)
    BottomSheetHost(onDismiss) {
        Text(stringResource(R.string.address_title), style = TypeScale.TITLE.style(white))
        Text(stringResource(R.string.address_hint), Modifier.padding(top = 4.dp, bottom = 12.dp), style = TypeScale.SECONDARY.style(dim))
        OutlinedTextField(
            text, { text = it; bad = false }, Modifier.fillMaxWidth(), singleLine = true, shape = RoundedCornerShape(14.dp),
            placeholder = { Text("192.168.1.20:47821", color = Color(Tokens.DARK.textFaint)) },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
            colors = OutlinedTextFieldDefaults.colors(
                focusedTextColor = white, unfocusedTextColor = white, cursorColor = white,
                focusedBorderColor = white, unfocusedBorderColor = Color.White.copy(alpha = 0.25f),
            ),
        )
        if (bad) Text(stringResource(R.string.address_bad), Modifier.padding(top = 8.dp), style = TypeScale.SECONDARY.style(Color(Tokens.DARK.danger)))
        PillButton(
            stringResource(R.string.address_save),
            { if (model.setAddress(text)) onDismiss() else bad = true },
            Modifier.fillMaxWidth().padding(top = 16.dp), PillKind.PRIMARY, enabled = text.isNotBlank(), onDark = true,
        )
    }
}
