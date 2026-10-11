package com.coucou.android.ui

import android.os.SystemClock
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.slideInVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import com.coucou.android.R
import com.coucou.android.app.AppModel
import com.coucou.android.core.ApprovalSheetPlan
import com.coucou.android.core.HomePanel
import com.coucou.android.core.IconKind
import com.coucou.android.core.IslandSurface
import com.coucou.android.core.MotionSpec
import com.coucou.android.core.Pills
import com.coucou.android.core.QuestionFlow
import com.coucou.android.link.AskedOption
import com.coucou.android.link.QuestionRequest
import com.coucou.android.core.Radii
import com.coucou.android.core.Spacing
import com.coucou.android.core.TypeScale
import com.coucou.android.link.ApprovalRequest
import com.coucou.android.mochi.BotState
import com.coucou.android.mochi.MochiConst
import com.coucou.android.mochi.MochiEngine
import com.coucou.android.mochi.MochiView
import kotlinx.coroutines.delay

/**
 * A panel that rises from the bottom over whatever is on screen, with a dim scrim behind it. It is black in
 * both themes, like the island it comes from. Tapping the scrim or pressing Back closes it; taps on the
 * panel itself never reach the scrim.
 */
@Composable
fun BottomSheetHost(onDismiss: () -> Unit, wash: Color? = null, content: @Composable ColumnScope.() -> Unit) {
    BackHandler(onBack = onDismiss)
    var shown by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { shown = true }
    val shape = RoundedCornerShape(topStart = Radii.SHEET.dp, topEnd = Radii.SHEET.dp)
    Box(Modifier.fillMaxSize()) {
        Box(
            Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.55f))
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onDismiss),
        )
        AnimatedVisibility(
            visible = shown, modifier = Modifier.align(Alignment.BottomCenter),
            enter = if (reducedMotion()) fadeIn(tween(MotionSpec.REDUCED_MS)) else slideInVertically(spring(dampingRatio = 0.72f, stiffness = 400f)) { it } + fadeIn(),
        ) {
            Column(
                Modifier.fillMaxWidth().clip(shape).background(Color(IslandSurface.PANEL)).border(1.dp, Color.White.copy(alpha = 0.08f), shape)
                    .then(if (wash != null) Modifier.drawBehind { drawWash(wash, 0.45f) } else Modifier)
                    .pointerInput(Unit) { detectTapGestures { } }
                    .padding(start = 20.dp, end = 20.dp, top = 10.dp, bottom = 20.dp),
                content = {
                    Box(Modifier.align(Alignment.CenterHorizontally).size(width = 36.dp, height = 4.dp).clip(RoundedCornerShape(2.dp)).background(Color.White.copy(alpha = 0.2f)))
                    Box(Modifier.size(14.dp))
                    content()
                },
            )
        }
    }
}

/** The colour of an agent for its Mochi: the user's choice on the computer, else the catalog's, else none. */
private fun agentColour(model: AppModel, pillId: String) =
    (model.sessions.firstOrNull { it.pillId == pillId }?.let { HomePanel.colorHex(it) } ?: Pills.byId(pillId)?.colorHex)?.let { HomePanel.rgb(it) }

@Composable
private fun SheetMochi(state: BotState, colour: com.coucou.android.mochi.Rgb?) {
    val engine = remember { MochiEngine({ SystemClock.elapsedRealtimeNanos() / 1e6 }).apply { setState(state, force = true) } }
    engine.bodyColor = colour
    MochiView(engine, Modifier.size(84.dp))
}

/**
 * A request for permission, in words: who, and what kind of action ("Wants to run a command"). The exact command is one tap
 * away ("Show exact command") and is always repeated by the lock prompt, so Allow is never blind. Allow needs the lock;
 * Deny does not. Taps in the first 600 ms are ignored.
 */
@Composable
fun ApprovalSheet(model: AppModel, r: ApprovalRequest, onAllow: (ApprovalRequest) -> Unit, onDismiss: () -> Unit) {
    var armed by remember(r.fingerprint) { mutableStateOf(false) }
    LaunchedEffect(r.fingerprint) { delay(ApprovalSheetPlan.GUARD_MS); armed = true }
    var showCommand by remember(r.fingerprint) { mutableStateOf(false) }
    val white = Color(IslandSurface.TEXT)
    val dim = Color(IslandSurface.TEXT_DIM)
    val wash = MochiConst.STATES[BotState.APPROVAL]?.color?.let(::rgbColor)
    val name = model.agentName(r.pillId)
    val kind = Pills.byId(r.pillId)?.name.orEmpty()
    BottomSheetHost(onDismiss, wash) {
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
            SheetMochi(BotState.APPROVAL, agentColour(model, r.pillId))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(if (kind.isNotBlank() && kind != name) "$name · $kind" else name, style = TypeScale.SECONDARY.style(dim), maxLines = 1)
                Text(stringResource(R.string.approval_wants, ApprovalSheetPlan.action(r.tool)), style = TypeScale.TITLE.style(white), maxLines = 3)
            }
        }
        Text(stringResource(R.string.approval_caution), Modifier.padding(top = 12.dp), style = TypeScale.SECONDARY.style(dim))
        Text(
            stringResource(if (showCommand) R.string.approval_hide_cmd else R.string.approval_show_cmd),
            Modifier.heightIn(min = Spacing.MIN_TOUCH.dp).clickable(role = Role.Button) { showCommand = !showCommand }.padding(vertical = 12.dp),
            style = TypeScale.SECONDARY.style(dim).copy(textDecoration = TextDecoration.Underline),
        )
        if (showCommand) {
            Column(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(Color.White.copy(alpha = 0.07f)).padding(12.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(r.tool, style = TypeScale.LABEL.style(dim), maxLines = 1)
                // The whole command that was sent, scrollable: never cut by a line limit.
                Column(Modifier.heightIn(max = ApprovalSheetPlan.COMMAND_BOX_MAX_DP.dp).verticalScroll(rememberScrollState())) {
                    Text(r.command, style = TypeScale.MONO.style(white).copy(fontFamily = FontFamily.Monospace))
                }
            }
            Box(Modifier.size(8.dp))
        }
        val canAllow = ApprovalSheetPlan.canAllowHere(r)
        if (!canAllow) {
            // Shown without a tap: the user must know the command is not all here before reading anything else.
            Text(stringResource(R.string.approval_too_long), Modifier.padding(bottom = 4.dp), style = TypeScale.TITLE.style(white))
            Text(stringResource(R.string.approval_on_computer), Modifier.padding(bottom = 10.dp), style = TypeScale.SECONDARY.style(dim))
        }
        Row(Modifier.fillMaxWidth().padding(top = 4.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            PillButton(stringResource(R.string.action_deny), { model.decide(r.fingerprint, allow = false) }, Modifier.weight(1f), onDark = true, enabled = armed)
            if (canAllow) {
                PillButton(
                    stringResource(R.string.action_allow), { onAllow(r) }, Modifier.weight(1f), PillKind.PRIMARY, enabled = armed, onDark = true,
                    icon = { CoucouIcon(IconKind.LOCK, tint = Color(IslandSurface.ON_PRIMARY), size = 18.dp) },
                )
            }
        }
        if (canAllow) Text(stringResource(R.string.approval_hint), Modifier.padding(top = 10.dp), style = TypeScale.LABEL.style(dim))
        Text(
            stringResource(R.string.approval_later),
            Modifier.heightIn(min = Spacing.MIN_TOUCH.dp).clickable(role = Role.Button, onClick = onDismiss).padding(vertical = 14.dp),
            style = TypeScale.SECONDARY.style(dim),
        )
    }
}

/**
 * A question Claude Code asks. With the `answers` capability the options are here to tap, one question at a time, and the answer
 * is sent only after the screen lock ([onSend]; the labels are the computer's exact ones, nothing typed ever goes in). Without it
 * the sheet says whose question it is and where to answer.
 */
@Composable
fun QuestionSheet(model: AppModel, pillId: String, onDismiss: () -> Unit, onSend: (QuestionRequest, List<List<String>>) -> Unit) {
    val white = Color(IslandSurface.TEXT)
    val dim = Color(IslandSurface.TEXT_DIM)
    val wash = MochiConst.STATES[BotState.QUESTION]?.color?.let(::rgbColor)
    val request = model.questionFor(pillId)
    BottomSheetHost(onDismiss, wash) {
        if (request == null) {
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
                SheetMochi(BotState.QUESTION, agentColour(model, pillId))
                Text(stringResource(R.string.question_title, model.agentName(pillId)), Modifier.weight(1f), style = TypeScale.TITLE.style(white), maxLines = 3)
            }
            Text(stringResource(R.string.question_body), Modifier.padding(top = 12.dp, bottom = 16.dp), style = TypeScale.BODY.style(dim))
            PillButton(stringResource(R.string.question_ok), onDismiss, Modifier.fillMaxWidth(), PillKind.PRIMARY, onDark = true)
            return@BottomSheetHost
        }
        var st by remember(request.fingerprint) { mutableStateOf(QuestionFlow.start(request.questions)) }
        var armed by remember(request.fingerprint) { mutableStateOf(false) }
        LaunchedEffect(request.fingerprint) { delay(ApprovalSheetPlan.GUARD_MS); armed = true }
        val q = request.questions[st.index.coerceIn(0, request.questions.lastIndex)]
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
            SheetMochi(BotState.QUESTION, agentColour(model, pillId))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(stringResource(R.string.question_title, model.agentName(pillId)), style = TypeScale.SECONDARY.style(dim), maxLines = 2)
                QuestionFlow.position(request.questions, st)?.let { (n, total) ->
                    Text(stringResource(R.string.question_position, n, total), style = TypeScale.LABEL.style(dim))
                }
            }
        }
        Text(q.question, Modifier.padding(top = 12.dp), style = TypeScale.HEADLINE.style(white))
        if (q.multiSelect) Text(stringResource(R.string.question_pick_many), Modifier.padding(top = 2.dp), style = TypeScale.SECONDARY.style(dim))
        Column(Modifier.padding(top = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            for (o in q.options) {
                OptionRow(o, selected = o.label in st.picks[st.index], multi = q.multiSelect) { st = QuestionFlow.toggle(request.questions, st, o.label) }
            }
        }
        Row(Modifier.fillMaxWidth().padding(top = 16.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            if (st.index > 0) PillButton(stringResource(R.string.question_back), { st = QuestionFlow.back(st) }, Modifier.weight(1f), onDark = true)
            if (QuestionFlow.isLast(request.questions, st)) {
                PillButton(
                    stringResource(R.string.question_send),
                    { QuestionFlow.picks(request.questions, st)?.let { onSend(request, it) } }, Modifier.weight(1f), PillKind.PRIMARY,
                    enabled = armed && QuestionFlow.complete(request.questions, st), onDark = true,
                    icon = { CoucouIcon(IconKind.LOCK, tint = Color(IslandSurface.ON_PRIMARY), size = 18.dp) },
                )
            } else {
                PillButton(
                    stringResource(R.string.question_next), { st = QuestionFlow.next(request.questions, st) }, Modifier.weight(1f), PillKind.PRIMARY,
                    enabled = QuestionFlow.canAdvance(request.questions, st), onDark = true,
                )
            }
        }
        Text(stringResource(R.string.approval_hint), Modifier.padding(top = 10.dp), style = TypeScale.LABEL.style(dim))
        Text(
            stringResource(R.string.approval_later),
            Modifier.heightIn(min = Spacing.MIN_TOUCH.dp).clickable(role = Role.Button, onClick = onDismiss).padding(vertical = 14.dp),
            style = TypeScale.SECONDARY.style(dim),
        )
    }
}

/** One option: a label, its description, and a mark that it is picked. Tapping it is the only way to answer. */
@Composable
private fun OptionRow(option: AskedOption, selected: Boolean, multi: Boolean, onClick: () -> Unit) {
    val white = Color(IslandSurface.TEXT)
    val dim = Color(IslandSurface.TEXT_DIM)
    val shape = RoundedCornerShape(16.dp)
    Row(
        Modifier.fillMaxWidth().heightIn(min = Spacing.MIN_TOUCH.dp).clip(shape)
            .background(Color.White.copy(alpha = if (selected) 0.16f else 0.07f))
            .border(1.dp, if (selected) white.copy(alpha = 0.7f) else Color.Transparent, shape)
            .selectable(selected = selected, role = if (multi) Role.Checkbox else Role.RadioButton, onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(22.dp).clip(if (multi) RoundedCornerShape(6.dp) else CircleShape)
                .background(if (selected) white else Color.Transparent)
                .border(1.5.dp, if (selected) white else dim, if (multi) RoundedCornerShape(6.dp) else CircleShape),
            contentAlignment = Alignment.Center,
        ) { if (selected) CoucouIcon(IconKind.CHECK, tint = Color(IslandSurface.ON_PRIMARY), size = 16.dp) }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(option.label, style = TypeScale.BODY.style(white).copy(fontWeight = FontWeight.SemiBold))
            if (option.description.isNotBlank()) Text(option.description, style = TypeScale.SECONDARY.style(dim))
        }
    }
}
