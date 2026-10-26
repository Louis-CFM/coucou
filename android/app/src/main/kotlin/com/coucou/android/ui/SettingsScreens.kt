package com.coucou.android.ui

import com.coucou.android.core.AgentMute
import com.coucou.android.core.TeamChoice
import androidx.compose.material3.OutlinedTextField
import androidx.compose.runtime.saveable.rememberSaveable
import android.content.Intent
import com.coucou.android.core.HistoryExport
import com.coucou.android.core.Languages
import com.coucou.android.app.AppLanguage
import androidx.compose.ui.platform.LocalContext
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.material3.AlertDialog
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.draw.alpha
import com.coucou.android.core.IconKind
import com.coucou.android.core.Spacing
import com.coucou.android.core.TypeScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.coucou.android.Attribution
import com.coucou.android.R
import com.coucou.android.app.AppModel
import com.coucou.android.app.Mode
import com.coucou.android.core.HistoryDays
import com.coucou.android.core.HomeText
import com.coucou.android.core.MotionChoice
import com.coucou.android.core.QuietHours
import com.coucou.android.core.ThemeChoice
import com.coucou.android.core.ThemePolicy
import com.coucou.android.core.VibrationChoice
import com.coucou.android.core.RelayLineKind
import com.coucou.android.core.RelayStatus
import com.coucou.android.link.LinkState
import com.coucou.android.sound.SoundVolume
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/**
 * The screen's title on one line; a long title is cut with "…". Sub-pages pass [onBack] and get a Back
 * button; the three tab screens pass null (the bar is their navigation) and get the plain title.
 */
@Composable
fun ScreenTitle(title: String, onBack: (() -> Unit)?, trailing: @Composable (() -> Unit)? = null) {
    if (onBack == null) {
        Row(Modifier.padding(top = Spacing.INSIDE.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(title, Modifier.weight(1f).padding(start = 4.dp), style = TypeScale.TITLE.style(tokens().text.c()), maxLines = 1, overflow = TextOverflow.Ellipsis)
            trailing?.invoke()
        }
        return
    }
    Row(Modifier.padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        TextButton(onClick = onBack) { Text(stringResource(R.string.action_back), maxLines = 1) }
        Text(title, Modifier.weight(1f), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        trailing?.invoke()
    }
}

/** A small heading above a card, the same on every screen. */
@Composable
fun SectionTitle(text: String) {
    Text(
        text, Modifier.padding(start = 4.dp, top = 4.dp),
        style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant, fontWeight = FontWeight.SemiBold,
        maxLines = 1,
    )
}

/** A setting with a switch at its end. */
@Composable
fun SettingSwitch(title: String, hint: String?, checked: Boolean, onChange: (Boolean) -> Unit) {
    ListRow(title, hint = hint, trailing = { CoucouSwitch(checked, onChange, label = title) })
}

/** A row that opens another page: its title and a chevron. */
@Composable
private fun LinkRow(title: String, onClick: () -> Unit) {
    ListRow(title, onClick = onClick, trailing = { CoucouIcon(IconKind.CHEVRON, tint = tokens().textDim.c(), size = 20.dp) })
}

private fun clock(min: Int) = "%02d:%02d".format(QuietHours.wrap(min) / 60, QuietHours.wrap(min) % 60)

/** A round 48 dp "−" or "+" button for stepping a time. */
@Composable
private fun StepButton(text: String, description: String, enabled: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.alpha(if (enabled) 1f else 0.4f).size(Spacing.MIN_TOUCH.dp).clip(CircleShape).background(tokens().secondaryButton.c())
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick).semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) { Text(text, style = TypeScale.HEADLINE.style(tokens().text.c())) }
}

@Composable
private fun TimeRow(label: String, minutes: Int, enabled: Boolean, onChange: (Int) -> Unit) {
    val t = tokens()
    Row(
        Modifier.fillMaxWidth().padding(horizontal = Spacing.INSIDE.dp, vertical = 4.dp).alpha(if (enabled) 1f else 0.5f),
        horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, Modifier.weight(1f), style = TypeScale.BODY.style(t.text.c()))
        StepButton("−", "$label, ${QuietHours.STEP} minutes earlier", enabled) { onChange(minutes - QuietHours.STEP) }
        Text(clock(minutes), Modifier.widthIn(min = 56.dp), style = TypeScale.BODY.style(t.text.c()).copy(fontFamily = FontFamily.Monospace), maxLines = 1)
        StepButton("+", "$label, ${QuietHours.STEP} minutes later", enabled) { onChange(minutes + QuietHours.STEP) }
    }
}

/** A title over a row of choices, one of them selected (read as radio buttons by TalkBack). */
@Composable
private fun <T> ChoiceRow(title: String, options: List<Pair<T, String>>, selected: T, onSelect: (T) -> Unit) {
    val t = tokens()
    Column(Modifier.padding(horizontal = Spacing.INSIDE.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, style = TypeScale.BODY.style(t.text.c()))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            for ((value, label) in options) {
                PillButton(
                    label, { onSelect(value) },
                    Modifier.weight(1f).semantics { this.selected = value == selected; role = Role.RadioButton },
                    if (value == selected) PillKind.PRIMARY else PillKind.SECONDARY,
                )
            }
        }
    }
}

/** The language of the app: the row shows the one in force; a tap opens the list (the phone's own first, then each language by its own name). */
@Composable
private fun LanguageRow() {
    val context = LocalContext.current
    val t = tokens()
    var open by remember { mutableStateOf(false) }
    val current = AppLanguage.current(context)
    val system = stringResource(R.string.language_system)
    val currentName = Languages.ALL.firstOrNull { it.tag == current }?.name ?: system
    ListRow(
        stringResource(R.string.settings_language), hint = currentName, onClick = { open = true },
        trailing = { CoucouIcon(IconKind.CHEVRON, tint = t.textDim.c(), size = 20.dp) },
    )
    if (open) {
        AlertDialog(
            onDismissRequest = { open = false },
            confirmButton = { TextButton(onClick = { open = false }) { Text(stringResource(R.string.action_cancel)) } },
            title = { Text(stringResource(R.string.settings_language)) },
            text = {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    Text(stringResource(R.string.language_picker_hint), Modifier.padding(bottom = 8.dp), style = TypeScale.SECONDARY.style(t.textDim.c()))
                    val options = listOf(Languages.SYSTEM to system) + Languages.ALL.map { it.tag to it.name }
                    for ((tag, label) in options) {
                        Row(
                            Modifier.fillMaxWidth().heightIn(min = Spacing.MIN_TOUCH.dp)
                                .selectable(selected = tag == current, role = Role.RadioButton) { open = false; AppLanguage.set(context, tag) }
                                .padding(vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            Text(label, Modifier.weight(1f), style = TypeScale.BODY.style(t.text.c()))
                            if (tag == current) CoucouIcon(IconKind.CHECK, tint = t.online.c(), size = 22.dp)
                        }
                    }
                }
            },
        )
    }
}

/** Room under a list so its last row can scroll above the floating bar (64 + 16 gap + 16 margin). */
val BarClearance = 96.dp

/**
 * Settings, a tab. Grouped, each group one panel: your computer (with Disconnect at the bottom, away
 * from the everyday switches), the island, sound, notices, more, and About (Louis Raillé's required notice).
 */
@Composable
fun SettingsScreen(model: AppModel, onHistory: () -> Unit, onGallery: () -> Unit, onWardrobe: () -> Unit, onOverlay: (Boolean) -> Unit, onDiagnostics: () -> Unit, onLicences: () -> Unit) {
    val s = model.settings
    val uri = LocalUriHandler.current
    val t = tokens()
    LazyColumn(
        Modifier.padding(horizontal = Gutter), contentPadding = PaddingValues(bottom = BarClearance),
        verticalArrangement = Arrangement.spacedBy(Gap),
    ) {
        item { ScreenTitle(stringResource(R.string.settings_title), null) }

        item { SectionHeading(stringResource(R.string.settings_section_computer)) }
        item {
            Panel {
                Row(Modifier.padding(Spacing.INSIDE.dp), horizontalArrangement = Arrangement.spacedBy(Spacing.GAP.dp), verticalAlignment = Alignment.CenterVertically) {
                    StateDot(linkDotColor(model))
                    Text(linkStatusText(model), Modifier.weight(1f), style = TypeScale.BODY.style(t.text.c()), maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
                when (model.mode) {
                    Mode.PAIRED -> {
                        RowDivider()
                        LinkRow(stringResource(R.string.diag_title), onDiagnostics)
                        RowDivider()
                        PillButton(stringResource(R.string.action_unpair), { model.unpair() }, Modifier.fillMaxWidth().padding(Spacing.INSIDE.dp), PillKind.DANGER)
                    }
                    Mode.DEMO -> {
                        RowDivider()
                        PillButton(stringResource(R.string.demo_leave), { model.stopDemo() }, Modifier.fillMaxWidth().padding(Spacing.INSIDE.dp))
                    }
                    Mode.NONE -> Text(
                        stringResource(R.string.settings_computer_none), Modifier.padding(start = Spacing.INSIDE.dp, end = Spacing.INSIDE.dp, bottom = Spacing.INSIDE.dp),
                        style = TypeScale.SECONDARY.style(t.textDim.c()),
                    )
                }
            }
        }

        if (RelayStatus.sectionVisible(model.mode == Mode.PAIRED, model.hasRelay)) {
            item { SectionHeading(stringResource(R.string.settings_section_away)) }
            item { RelayCard(model) }
        }

        if (model.batteryHintVisible) item { BatteryCard(model) }

        item { SectionHeading(stringResource(R.string.settings_section_display)) }
        item {
            Panel {
                LanguageRow()
                RowDivider()
                ChoiceRow(
                    stringResource(R.string.settings_theme),
                    listOf(
                        ThemeChoice.SYSTEM to stringResource(R.string.theme_system),
                        ThemeChoice.LIGHT to stringResource(R.string.theme_light),
                        ThemeChoice.DARK to stringResource(R.string.theme_dark),
                    ),
                    s.theme,
                ) { model.updateSettings(s.copy(theme = it)) }
                if (ThemePolicy.dynamicAvailable(android.os.Build.VERSION.SDK_INT)) {
                    RowDivider()
                    SettingSwitch(stringResource(R.string.settings_dynamic), stringResource(R.string.settings_dynamic_hint), s.dynamicColour) {
                        model.updateSettings(s.copy(dynamicColour = it))
                    }
                }
                RowDivider()
                SettingSwitch(stringResource(R.string.overlay_title), stringResource(R.string.overlay_hint), model.overlayOn, onOverlay)
                RowDivider()
                ChoiceRow(
                    stringResource(R.string.settings_motion),
                    listOf(
                        MotionChoice.SYSTEM to stringResource(R.string.motion_system),
                        MotionChoice.REDUCE to stringResource(R.string.motion_on),
                        MotionChoice.FULL to stringResource(R.string.motion_off),
                    ),
                    s.motion,
                ) { model.updateSettings(s.copy(motion = it)) }
                Text(
                    stringResource(R.string.settings_motion_hint),
                    Modifier.padding(horizontal = Spacing.INSIDE.dp).padding(bottom = 12.dp),
                    style = TypeScale.SECONDARY.style(t.textDim.c()),
                )
            }
        }

        item { SectionHeading(stringResource(R.string.settings_section_sound)) }
        item {
            Panel {
                SettingSwitch(stringResource(R.string.settings_sound), null, s.soundOn) { model.updateSettings(s.copy(soundOn = it)) }
                RowDivider()
                Column(Modifier.padding(horizontal = Spacing.INSIDE.dp, vertical = 8.dp)) {
                    Row {
                        Text(stringResource(R.string.settings_volume), Modifier.weight(1f), style = TypeScale.BODY.style(t.text.c()))
                        Text("${(s.volume / SoundVolume.MAX * 100).toInt().coerceIn(0, 100)}%", style = TypeScale.SECONDARY.style(t.textDim.c()))
                    }
                    CoucouSlider(
                        value = s.volume, onChange = { model.updateSettings(s.copy(volume = SoundVolume.clamp(it))) },
                        valueRange = 0f..SoundVolume.MAX, enabled = s.soundOn, label = stringResource(R.string.settings_volume),
                    )
                }
            }
        }

        item { SectionHeading(stringResource(R.string.settings_section_requests)) }
        item {
            Panel {
                SettingSwitch(stringResource(R.string.settings_no_wake), stringResource(R.string.settings_no_wake_hint), s.keepScreenOff) {
                    model.updateSettings(s.copy(keepScreenOff = it))
                }
                RowDivider()
                ChoiceRow(
                    stringResource(R.string.settings_vibration),
                    listOf(
                        VibrationChoice.STANDARD to stringResource(R.string.vibration_standard),
                        VibrationChoice.SHORT to stringResource(R.string.vibration_short),
                        VibrationChoice.OFF to stringResource(R.string.vibration_off),
                    ),
                    s.vibration,
                ) { model.updateSettings(s.copy(vibration = it)) }
                Text(
                    stringResource(R.string.settings_requests_note),
                    Modifier.padding(horizontal = Spacing.INSIDE.dp).padding(bottom = 12.dp),
                    style = TypeScale.SECONDARY.style(t.textDim.c()),
                )
            }
        }

        item { SectionHeading(stringResource(R.string.settings_section_notices)) }
        item {
            Panel {
                SettingSwitch(stringResource(R.string.notify_done), stringResource(R.string.notify_done_hint), s.notifyDone) {
                    model.updateSettings(s.copy(notifyDone = it))
                }
                RowDivider()
                SettingSwitch(stringResource(R.string.quiet_hours), stringResource(R.string.quiet_hint), s.quiet.enabled) {
                    model.updateSettings(s.copy(quiet = s.quiet.copy(enabled = it)))
                }
                TimeRow(stringResource(R.string.quiet_from), s.quiet.fromMin, s.quiet.enabled) {
                    model.updateSettings(s.copy(quiet = s.quiet.copy(fromMin = QuietHours.wrap(it))))
                }
                TimeRow(stringResource(R.string.quiet_to), s.quiet.toMin, s.quiet.enabled) {
                    model.updateSettings(s.copy(quiet = s.quiet.copy(toMin = QuietHours.wrap(it))))
                }
                RowDivider()
                MutedAgentsRows(s.mutedAgents) { id, mute -> model.updateSettings(s.copy(mutedAgents = AgentMute.with(s.mutedAgents, id, mute))) }
                Spacer(Modifier.height(8.dp))
            }
        }

        item { SectionHeading(stringResource(R.string.settings_section_more)) }
        item {
            Panel {
                LinkRow(stringResource(R.string.history_title), onHistory)
                RowDivider()
                LinkRow(stringResource(R.string.wardrobe_title), onWardrobe)
                RowDivider()
                LinkRow(stringResource(R.string.gallery), onGallery)
            }
        }

        // Required by Louis Raillé's permission: visible, one tap from Home.
        item { SectionHeading(stringResource(R.string.settings_section_about)) }
        item {
            Panel {
                Column(Modifier.padding(Spacing.INSIDE.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(stringResource(R.string.about_credit), style = TypeScale.BODY.style(t.text.c()))
                    Text(
                        stringResource(R.string.about_repo),
                        Modifier.heightIn(min = Spacing.MIN_TOUCH.dp).clickable(role = Role.Button) { runCatching { uri.openUri(Attribution.REPO_URL) } }.padding(vertical = 14.dp),
                        style = TypeScale.BODY.style(t.text.c()).copy(textDecoration = TextDecoration.Underline),
                    )
                    Text(stringResource(R.string.about_assets), style = TypeScale.SECONDARY.style(t.textDim.c()))
                }
                RowDivider()
                LinkRow(stringResource(R.string.licences_title), onLicences)
            }
        }
        item { Spacer(Modifier.height(Gutter)) }
    }
}

/**
 * What you allowed or denied, in sentences (never the command or a path), grouped by day. Kept only on the
 * phone. The same list as Home's "Recent", in full.
 */
@Composable
fun HistoryScreen(model: AppModel, onBack: () -> Unit) {
    val zone = remember { ZoneId.systemDefault() }
    val now = System.currentTimeMillis()
    var query by rememberSaveable { mutableStateOf("") }
    val shown = HistoryExport.filter(model.decisions, query)
    val groups = HistoryDays.group(shown, now, zone)
    val context = LocalContext.current
    val exportHeader = stringResource(R.string.history_export_header)
    val dateFormat = remember { DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM) }
    val timeFormat = remember { DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT) }
    val t = tokens()
    LazyColumn(Modifier.padding(horizontal = Gutter), verticalArrangement = Arrangement.spacedBy(Gap)) {
        item { ScreenTitle(stringResource(R.string.history_title), onBack) }
        item { Text(stringResource(R.string.history_note), Modifier.padding(horizontal = 4.dp), style = TypeScale.SECONDARY.style(t.textDim.c())) }
        if (model.decisions.isNotEmpty()) {
            item {
                OutlinedTextField(
                    value = query, onValueChange = { query = it.take(HistoryExport.MAX_QUERY) }, singleLine = true,
                    label = { Text(stringResource(R.string.history_search)) }, modifier = Modifier.fillMaxWidth(),
                )
            }
        }
        if (model.decisions.isNotEmpty() && groups.isEmpty()) {
            item { Panel { Text(stringResource(R.string.history_no_match), Modifier.padding(Gutter), style = TypeScale.BODY.style(t.textDim.c())) } }
        }
        if (groups.isEmpty() && model.decisions.isEmpty()) {
            item { Panel { Text(stringResource(R.string.history_empty), Modifier.padding(Gutter), style = TypeScale.BODY.style(t.textDim.c())) } }
        }
        for ((key, list) in groups) {
            val (day, date) = key
            item {
                SectionHeading(
                    when (day) {
                        HistoryDays.Day.TODAY -> stringResource(R.string.history_today)
                        HistoryDays.Day.YESTERDAY -> stringResource(R.string.history_yesterday)
                        HistoryDays.Day.OTHER -> dateFormat.format(date)
                    },
                )
            }
            item {
                Panel {
                    list.forEachIndexed { i, d ->
                        if (i > 0) RowDivider()
                        Row(
                            Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(horizontal = Spacing.INSIDE.dp, vertical = 12.dp),
                            horizontalArrangement = Arrangement.spacedBy(Spacing.GAP.dp), verticalAlignment = Alignment.CenterVertically,
                        ) {
                            StateDot(if (d.allowed) StatusColors.online else t.danger.c())
                            Text(HomeText.decision(d.allowed, d.agent, d.tool), Modifier.weight(1f), style = TypeScale.BODY.style(t.text.c()), maxLines = 2, overflow = TextOverflow.Ellipsis)
                            Text(
                                timeFormat.format(java.time.Instant.ofEpochMilli(d.atMs).atZone(zone).toLocalTime()),
                                style = TypeScale.SECONDARY.style(t.textDim.c()), maxLines = 1,
                            )
                        }
                    }
                }
            }
        }
        if (groups.isNotEmpty()) {
            item {
                PillButton(
                    stringResource(R.string.history_export),
                    {
                        // Plain text to Android's share sheet: it stays on the phone until the user picks where it goes.
                        val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, HistoryExport.text(shown, exportHeader, zone))
                        context.startActivity(Intent.createChooser(send, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    },
                    Modifier.fillMaxWidth(),
                )
            }
        }
        if (groups.isNotEmpty() && query.isBlank()) {
            item { PillButton(stringResource(R.string.history_clear), { model.clearDecisions() }, Modifier.fillMaxWidth(), PillKind.DANGER) }
        }
        item { Spacer(Modifier.height(Gutter)) }
    }
}

/**
 * "Away from home Wi-Fi": whether this phone also reaches the computer through the relay, and which way it is connected
 * right now. The switch is shown only when the pairing includes a relay (the computer's switch was on when it was paired).
 */
@Composable
private fun RelayCard(model: AppModel) {
    val t = tokens()
    val s = model.settings
    val kind = RelayStatus.kind(model.hasRelay, s.useRelay, model.linkState == LinkState.CONNECTED, model.route, model.relayIssue)
    val line = when (kind) {
        RelayLineKind.NO_RELAY_IN_PAIRING -> stringResource(R.string.relay_line_none)
        RelayLineKind.SWITCHED_OFF -> stringResource(R.string.relay_line_off)
        RelayLineKind.DIRECT -> stringResource(R.string.relay_line_direct)
        RelayLineKind.VIA_RELAY -> stringResource(R.string.relay_line_via, model.relayHost.orEmpty())
        RelayLineKind.WAITING -> stringResource(R.string.relay_line_waiting)
        RelayLineKind.ACCESS_REFUSED -> stringResource(R.string.relay_line_access)
        RelayLineKind.ROOM_TAKEN -> stringResource(R.string.relay_line_taken)
        RelayLineKind.RATE_LIMITED -> stringResource(R.string.relay_line_rate)
        RelayLineKind.UNREACHABLE -> stringResource(R.string.relay_line_unreachable)
        RelayLineKind.COMPUTER_AWAY -> stringResource(R.string.relay_line_away)
    }
    Panel {
        if (model.hasRelay) {
            SettingSwitch(stringResource(R.string.relay_use), stringResource(R.string.relay_use_hint), s.useRelay) {
                model.updateSettings(s.copy(useRelay = it))
            }
            RowDivider()
        }
        Text(line, Modifier.padding(Spacing.INSIDE.dp), style = TypeScale.SECONDARY.style(t.textDim.c()))
    }
}

/**
 * "Mute an agent's notices": a row that opens the list of agents, each with a switch. Only the finished / failed / limit notices of the agent
 * go quiet; its requests and questions always come through (said under the list).
 */
@Composable
private fun MutedAgentsRows(muted: Set<String>, onChange: (String, Boolean) -> Unit) {
    var open by rememberSaveable { mutableStateOf(false) }
    ListRow(
        stringResource(R.string.mute_agents), hint = stringResource(R.string.mute_agents_hint), onClick = { open = !open },
        trailing = { if (muted.isNotEmpty()) Text(muted.size.toString(), style = TypeScale.SECONDARY.style(tokens().textDim.c())) },
    )
    if (open) {
        for (pill in AgentMute.candidates) {
            RowDivider()
            SettingSwitch(TeamChoice.nameOf(pill.id), null, pill.id in muted) { onChange(pill.id, it) }
        }
    }
}
