package com.coucou.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.coucou.android.R
import com.coucou.android.app.AppModel
import com.coucou.android.core.IconKind
import com.coucou.android.core.LaunchAvailability
import com.coucou.android.core.LaunchFlow
import com.coucou.android.core.LaunchOutcome
import com.coucou.android.core.Spacing
import com.coucou.android.core.Tokens
import com.coucou.android.core.TypeScale
import com.coucou.android.link.LaunchProject
import com.coucou.android.link.Protocol

/** The row on Home that opens the sheet: "New Claude Code session", with a chevron like the rows of Settings. */
@Composable
fun LaunchRow(onClick: () -> Unit) {
    Panel {
        ListRow(
            stringResource(R.string.launch_title), hint = stringResource(R.string.launch_row_hint), onClick = onClick,
            trailing = { CoucouIcon(IconKind.CHEVRON, tint = tokens().textDim.c(), size = 20.dp) },
        )
    }
}

/**
 * "New Claude Code session": the projects the computer offers (folder names, tapped, never typed), what Claude should do, and Send, which
 * goes through the screen lock ([onSend]) like Allow. When the computer does not offer it, is not reachable or has no project yet, the
 * sheet says so instead. After sending it says what became of the request: sent, refused and why, or no answer.
 */
@Composable
fun LaunchSheet(model: AppModel, onDismiss: () -> Unit, onSend: (LaunchProject, String) -> Unit) {
    val white = Color(tokens().heroText)
    val dim = Color(tokens().heroTextDim)
    val danger = Color(Tokens.DARK.danger)
    val title = stringResource(R.string.launch_title)
    var chosen by rememberSaveable { mutableStateOf<String?>(null) }
    var text by rememberSaveable { mutableStateOf("") }
    BottomSheetHost(onDismiss, announce = title) {
        Text(title, style = TypeScale.TITLE.style(white))
        model.desktopName?.takeIf { it.isNotBlank() }?.let {
            Text(it, Modifier.padding(top = 2.dp), style = TypeScale.SECONDARY.style(dim), maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        val outcome = model.launchOutcome
        if (outcome is LaunchOutcome.Sent) {
            Text(stringResource(R.string.launch_sent, outcome.project), Modifier.padding(top = 12.dp, bottom = 16.dp), style = TypeScale.BODY.style(white))
            PillButton(stringResource(R.string.question_ok), onDismiss, Modifier.fillMaxWidth(), PillKind.PRIMARY, onDark = true)
            return@BottomSheetHost
        }
        val unavailable = when (model.launchAvailability) {
            LaunchAvailability.NOT_CONNECTED -> stringResource(R.string.launch_not_connected) to null
            LaunchAvailability.NOT_OFFERED -> stringResource(R.string.launch_unsupported_title) to stringResource(R.string.launch_unsupported_body)
            LaunchAvailability.NO_PROJECTS -> stringResource(R.string.launch_no_projects) to null
            LaunchAvailability.READY -> null
        }
        // What became of a request is said even when the computer has gone away since (no answer, not sent).
        val problem = when (outcome) {
            is LaunchOutcome.Refused -> LaunchFlow.refusal(outcome.reason)
            LaunchOutcome.NoAnswer -> stringResource(R.string.launch_no_answer)
            LaunchOutcome.NotSent -> stringResource(R.string.launch_not_connected)
            else -> null
        }
        if (unavailable != null) {
            if (problem != null && problem != unavailable.first) Text(problem, Modifier.padding(top = 12.dp), style = TypeScale.BODY.style(danger))
            Text(unavailable.first, Modifier.padding(top = 12.dp), style = TypeScale.BODY.style(white))
            unavailable.second?.let { Text(it, Modifier.padding(top = 6.dp), style = TypeScale.SECONDARY.style(dim)) }
            PillButton(stringResource(R.string.question_ok), onDismiss, Modifier.fillMaxWidth().padding(top = 16.dp), PillKind.PRIMARY, onDark = true)
            return@BottomSheetHost
        }
        val projects = model.launchProjects
        val picked = LaunchFlow.pick(projects, chosen)
        val sending = outcome is LaunchOutcome.Sending
        Text(stringResource(R.string.launch_choose), Modifier.padding(top = 14.dp, bottom = 8.dp), style = TypeScale.LABEL.style(dim))
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            for (p in projects) ProjectRow(p.name, selected = p.id == picked?.id, enabled = !sending) { chosen = p.id }
        }
        OutlinedTextField(
            text, { text = it }, Modifier.fillMaxWidth().padding(top = 14.dp), enabled = !sending,
            minLines = 2, maxLines = 6, shape = RoundedCornerShape(14.dp),
            placeholder = { Text(stringResource(R.string.launch_prompt_hint), color = Color(Tokens.DARK.textFaint)) },
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
            colors = OutlinedTextFieldDefaults.colors(
                focusedTextColor = white, unfocusedTextColor = white, disabledTextColor = dim, cursorColor = white,
                focusedBorderColor = white, unfocusedBorderColor = Color(tokens().heroText).copy(alpha = 0.25f),
                disabledBorderColor = Color(tokens().heroText).copy(alpha = 0.15f),
            ),
        )
        if (LaunchFlow.problem(text) == LaunchFlow.Problem.TOO_LONG) {
            Text(stringResource(R.string.launch_too_long, Protocol.LAUNCH_MAX_TEXT), Modifier.padding(top = 8.dp), style = TypeScale.SECONDARY.style(danger))
        }
        if (problem != null) Text(problem, Modifier.padding(top = 10.dp), style = TypeScale.SECONDARY.style(danger))
        PillButton(
            stringResource(if (sending) R.string.launch_sending else R.string.launch_send),
            { picked?.let { onSend(it, text) } }, Modifier.fillMaxWidth().padding(top = 16.dp), PillKind.PRIMARY,
            enabled = LaunchFlow.canSend(model.launchAvailability, picked, text, outcome), onDark = true,
            icon = { CoucouIcon(IconKind.LOCK, tint = Color(tokens().heroOnPrimary), size = 18.dp) },
        )
        Text(stringResource(R.string.launch_lock_hint), Modifier.padding(top = 10.dp), style = TypeScale.LABEL.style(dim))
    }
}

/** One project: its folder name and a mark that it is picked. Tapping one is the only way to choose where the session starts. */
@Composable
private fun ProjectRow(name: String, selected: Boolean, enabled: Boolean, onClick: () -> Unit) {
    val white = Color(tokens().heroText)
    val dim = Color(tokens().heroTextDim)
    val shape = RoundedCornerShape(16.dp)
    Row(
        Modifier.fillMaxWidth().heightIn(min = Spacing.MIN_TOUCH.dp).clip(shape)
            .background(Color(tokens().heroText).copy(alpha = if (selected) 0.16f else 0.07f))
            .border(1.dp, if (selected) white.copy(alpha = 0.7f) else Color.Transparent, shape)
            .selectable(selected = selected, enabled = enabled, role = Role.RadioButton, onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(22.dp).clip(CircleShape).background(if (selected) white else Color.Transparent).border(1.5.dp, if (selected) white else dim, CircleShape),
            contentAlignment = Alignment.Center,
        ) { if (selected) CoucouIcon(IconKind.CHECK, tint = Color(tokens().heroOnPrimary), size = 16.dp) }
        Text(name, Modifier.weight(1f), style = TypeScale.BODY.style(white).copy(fontWeight = FontWeight.SemiBold), maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}
