package fr.louisraille.coucou.phone

import android.os.Build
import android.provider.Settings
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import fr.louisraille.coucou.phone.outfit.Outfit
import fr.louisraille.coucou.phone.outfit.Wardrobe
import java.time.LocalDate
import kotlinx.coroutines.launch

// MARK: - Pairing

@Composable
fun PairScreen(vm: CoucouViewModel) {
    var worker by rememberSaveable { mutableStateOf("") }
    var code by rememberSaveable { mutableStateOf("") }
    var name by rememberSaveable { mutableStateOf(Build.MODEL) }

    Column(
        Modifier
            .fillMaxSize()
            .safeDrawingPadding()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.height(56.dp))
        Mochi(MochiSpec.State.Idle, Modifier.size(96.dp), seed = "pair")
        Spacer(Modifier.height(20.dp))
        Text(stringResource(R.string.app_name), fontSize = 28.sp, fontWeight = FontWeight.Bold, color = Coucou.Ink)
        Text(
            stringResource(R.string.pair_tagline),
            color = Coucou.Secondary,
            fontSize = 15.sp,
            modifier = Modifier.padding(top = 6.dp),
        )
        Spacer(Modifier.height(36.dp))
        CoucouField(
            value = code,
            onValueChange = {
                code = it
                // The PC shows id|secret|worker — a full paste fills the URL too.
                val parts = it.trim().split('|')
                if (worker.isBlank() && parts.size >= 3) worker = parts[2].trim()
            },
            hint = stringResource(R.string.pair_code_hint),
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(10.dp))
        CoucouField(
            value = worker,
            onValueChange = { worker = it },
            hint = stringResource(R.string.pair_relay_hint),
            keyboardType = KeyboardType.Uri,
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(10.dp))
        CoucouField(
            value = name,
            onValueChange = { name = it },
            hint = stringResource(R.string.pair_name_hint),
            modifier = Modifier.fillMaxWidth(),
        )
        if (vm.pairError != null) {
            Text(
                vm.pairError!!,
                color = Coucou.Error,
                fontSize = 13.sp,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 14.dp),
            )
        }
        Spacer(Modifier.height(24.dp))
        PillButton(
            text = stringResource(if (vm.busy) R.string.status_connecting else R.string.connect),
            onClick = { vm.pair(worker, code, name) },
            filled = true,
            enabled = !vm.busy && code.isNotBlank(),
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(40.dp))
    }
}

// MARK: - Home

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(vm: CoucouViewModel) {
    val box = vm.box
    val card = box?.pending?.takeUnless { vm.isAnswered(it.requestId) }
    val sent = box?.pending?.let { vm.sentDecision(it.requestId) }
    val sessions = box?.state?.sessions.orEmpty()
    val lead = remember(box, card) {
        if (card != null) null else sessions.maxByOrNull { urgencyOf(it.state) }
    }
    val running = sessions.count { it.state == "working" || it.state == "thinking" || it.state == "searching" }

    // The hero hangs from the top edge and takes the status bar inset itself.
    Column(Modifier.fillMaxSize()) {
        HeroCard(
            box = box,
            pending = card,
            sent = sent,
            lead = lead,
            running = running,
            lineError = vm.lineError,
            outfit = Wardrobe.resolve(vm.outfitSel, LocalDate.now()),
        )
        PullToRefreshBox(
            isRefreshing = vm.refreshing,
            onRefresh = { vm.refreshNow() },
            modifier = Modifier.weight(1f),
        ) {
            LazyColumn(
                Modifier.fillMaxSize(),
                verticalArrangement = Arrangement.spacedBy(12.dp),
                contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 16.dp),
            ) {
                if (card != null || sent != null) {
                    item { PendingPanel(card = card, sent = sent, vm = vm) }
                }

                // The other agents — the hero carries the lead.
                val others = sessions.filter { it.pillId != lead?.pillId }
                if (others.isNotEmpty()) {
                    item {
                        CoucouCard(modifier = Modifier.fillMaxWidth()) {
                            Column {
                                others.forEachIndexed { i, s ->
                                    AgentRow(s)
                                    if (i < others.size - 1) RowDivider()
                                }
                            }
                        }
                    }
                }

                // One CLI at a time — the header's ▾ switches which agent shows.
                run {
                    val all = box?.state?.chatSessions.orEmpty()
                    val agents = (listOf("devin", "claude", "codex", "opencode") + all.map { it.agent }).distinct()
                    item {
                        AgentSection(
                            agent = vm.pickerAgent,
                            agents = agents,
                            sessions = all.filter { it.agent == vm.pickerAgent }.sortedByDescending { it.at },
                            onAgent = { vm.pickAgent(it) },
                            onPick = { s -> vm.selectSession(s); vm.navigate(CoucouViewModel.Screen.CHAT) },
                            onAll = { vm.openPicker(vm.pickerAgent) },
                        )
                    }
                }
            }
        }
    }
}

/**
 * The hero of Home — the upstream island grown to full width and hanging from
 * the top edge: the connection line, the lead session's big Mochi in its state
 * colour's glow, its name and one plain sentence. Buttons live in the pending
 * card below, so the hero stays a read-out, not a control.
 */
@Composable
private fun HeroCard(
    box: Relay.Fetch?,
    pending: Relay.Card?,
    sent: String?,
    lead: Relay.Session?,
    running: Int,
    lineError: String?,
    outfit: Outfit = Outfit.NONE,
) {
    val connected = box != null && lineError == null
    val wash = when {
        pending != null -> if (pending.isQuestion) Coucou.Question else Coucou.Approval
        lead != null -> Coucou.accentFor(lead.state)
        else -> null
    }
    HeroPanel(wash = wash) {
        Column(
            Modifier
                .windowInsetsPadding(WindowInsets.statusBars)
                .padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 18.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            // ● Connected · N running — the one status line of the screen.
            Row(verticalAlignment = Alignment.CenterVertically) {
                StateDot(
                    if (connected) Coucou.Done
                    else if (lineError != null) Coucou.Error
                    else Coucou.Sleeping,
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    stringResource(
                        if (connected) R.string.status_connected
                        else if (lineError != null) R.string.status_offline
                        else R.string.status_connecting,
                    ),
                    color = Coucou.Secondary,
                    fontSize = 13.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                if (running > 0) Text(stringResource(R.string.status_running, running), color = Coucou.Secondary, fontSize = 13.sp)
            }

            if (pending == null && lead == null) {
                // Empty: the big quiet Mochi, centred, says it all.
                Column(
                    Modifier.fillMaxWidth(),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Mochi(MochiSpec.State.Sleeping, Modifier.size(112.dp), seed = "empty", outfit = outfit)
                    Text(
                        stringResource(
                            if (lineError != null) R.string.error_relay_unreachable
                            else if (box == null) R.string.home_waiting_pc
                            else R.string.home_all_quiet,
                        ),
                        color = Coucou.Ink,
                        fontSize = 20.sp,
                        fontWeight = FontWeight.Bold,
                    )
                    Text(
                        lineError
                            ?: stringResource(R.string.home_sessions_hint),
                        color = if (lineError != null) Coucou.Error else Coucou.Secondary,
                        fontSize = 13.sp,
                        maxLines = 3,
                    )
                }
            } else {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    val state = when {
                        pending != null -> if (pending.isQuestion) MochiSpec.State.Question else MochiSpec.State.Approval
                        else -> MochiSpec.State.of(lead!!.state)
                    }
                    Mochi(state, Modifier.size(108.dp), seed = pending?.requestId ?: lead!!.pillId, outfit = outfit)
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(
                            if (pending != null) agentTitle(pending.agent) else agentTitle(lead!!.agent),
                            color = Coucou.Ink,
                            fontSize = 20.sp,
                            fontWeight = FontWeight.Bold,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                        )
                        if (pending != null) {
                            Text(
                                stringResource(if (pending.isQuestion) R.string.card_needs_answer else R.string.card_waiting_ok),
                                color = if (pending.isQuestion) Coucou.Question else Coucou.Approval,
                                fontSize = 13.sp,
                                fontWeight = FontWeight.SemiBold,
                            )
                        }
                        Text(
                            when {
                                pending != null -> pending.title
                                sent != null -> stringResource(if (sent == "allow") R.string.sent_allowed else R.string.sent_generic)
                                lead!!.statusText.isNotBlank() -> lead.statusText
                                else -> lead.state
                            },
                            color = Coucou.Ink,
                            fontSize = 16.sp,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 3,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.padding(top = 4.dp),
                        )
                    }
                }
            }
        }
    }
}


/** The CLI's display name — ids come from the PC ("devin", "claude", …). */
private fun agentTitle(agent: String): String = when (agent) {
    "devin" -> "Devin"
    "claude" -> "Claude Code"
    "codex" -> "ChatGPT"
    "opencode" -> "OpenCode"
    "cursor" -> "Cursor"
    "kiro" -> "Kiro"
    else -> agent.replaceFirstChar { it.uppercase() }
}

/**
 * Tool-call accent — the iOS look where commands stand out in blue.
 * shell/exec → blue, edits → orange, reads/searches → green, web → cyan,
 * plans/todos → purple, everything else falls back to tertiary grey.
 */
private fun toolColor(name: String): Color {
    val n = name.lowercase()
    return when {
        n.contains("exec") || n.contains("bash") || n.contains("shell") ||
            n.contains("cmd") || n.contains("powershell") || n.contains("run") ||
            n.contains("terminal") -> Color(0xFF0A84FF)
        n.contains("edit") || n.contains("write") || n.contains("patch") ||
            n.contains("apply") || n.contains("create") -> Color(0xFFFF9F0A)
        n.contains("read") || n.contains("view") || n.contains("glob") ||
            n.contains("grep") || n.contains("find") || n.contains("search") ||
            n.contains("list") || n == "ls" -> Color(0xFF30D158)
        n.contains("web") || n.contains("fetch") || n.contains("browse") ||
            n.contains("http") || n.contains("url") -> Color(0xFF64D2FF)
        n.contains("think") || n.contains("plan") || n.contains("todo") ||
            n.contains("task") -> Color(0xFFBF5AF2)
        else -> Coucou.Tertiary
    }
}

/** "now" / "12m" / "3h" / "4d" — the picker rows' right-hand time. */
@Composable
private fun ago(at: Long): String {
    if (at <= 0) return ""
    val s = System.currentTimeMillis() / 1000 - at
    return when {
        s < 60 -> stringResource(R.string.ago_now)
        s < 3600 -> stringResource(R.string.ago_minutes, s / 60)
        s < 86400 -> stringResource(R.string.ago_hours, s / 3600)
        else -> stringResource(R.string.ago_days, s / 86400)
    }
}

/** The wardrobe pick's display name — the PC's outfit ids to local labels. */
@Composable
private fun wardrobeLabel(sel: String): String {
    val res = when (sel) {
        "auto" -> R.string.wardrobe_auto
        "none" -> R.string.wardrobe_none
        "partyHat" -> R.string.wardrobe_party_hat
        "beanie" -> R.string.wardrobe_beanie
        "crown" -> R.string.wardrobe_crown
        "sunglasses" -> R.string.wardrobe_sunglasses
        "roundGlasses" -> R.string.wardrobe_round_glasses
        "bow" -> R.string.wardrobe_bow
        "scarf" -> R.string.wardrobe_scarf
        "witchHat" -> R.string.wardrobe_witch_hat
        "pumpkin" -> R.string.wardrobe_pumpkin
        "santaHat" -> R.string.wardrobe_santa_hat
        "bunnyEars" -> R.string.wardrobe_bunny_ears
        else -> return sel
    }
    return stringResource(res)
}

/** One agent's section on Home: ▾-switchable header + its three newest sessions. */
@Composable
private fun AgentSection(
    agent: String,
    agents: List<String>,
    sessions: List<Relay.ChatSession>,
    onAgent: (String) -> Unit,
    onPick: (Relay.ChatSession) -> Unit,
    onAll: () -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    Column {
        Row(
            Modifier
                .fillMaxWidth()
                .padding(start = 4.dp, bottom = 6.dp, top = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box {
                Row(
                    Modifier
                        .clip(RoundedCornerShape(8.dp))
                        .clickable { menu = true }
                        .padding(horizontal = 8.dp, vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        agentTitle(agent),
                        color = Coucou.Secondary,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(" ▾", color = Coucou.Tertiary, fontSize = 13.sp)
                }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    agents.forEach { a ->
                        DropdownMenuItem(
                            text = {
                                Text(
                                    agentTitle(a),
                                    fontWeight = if (a == agent) FontWeight.Bold else FontWeight.Normal,
                                )
                            },
                            onClick = { onAgent(a); menu = false },
                        )
                    }
                }
            }
            Spacer(Modifier.weight(1f))
            Text(
                stringResource(R.string.sessions_all, sessions.size),
                color = Coucou.Tertiary,
                fontSize = 13.sp,
                modifier = Modifier
                    .clip(CircleShape)
                    .clickable(onClick = onAll)
                    .padding(horizontal = 8.dp, vertical = 4.dp),
            )
        }
        CoucouCard(modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.padding(horizontal = 14.dp, vertical = 4.dp)) {
                if (sessions.isEmpty()) {
                    Text(
                        stringResource(R.string.no_agent_chats, agentTitle(agent)),
                        color = Coucou.Tertiary,
                        fontSize = 14.sp,
                        modifier = Modifier.padding(vertical = 14.dp),
                    )
                }
                sessions.take(3).forEachIndexed { i, s ->
                    CliSessionRow(s, onClick = { onPick(s) })
                    if (i < sessions.take(3).size - 1) RowDivider()
                }
            }
        }
    }
}

/** One CLI session row — title, folder, how long ago. Whole row is the tap. */
@Composable
private fun CliSessionRow(s: Relay.ChatSession, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .clickable(onClick = onClick)
            .padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(
                s.title.ifBlank { s.id },
                color = Coucou.Ink,
                fontSize = 15.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (s.dir.isNotBlank()) {
                Text(
                    s.dir,
                    color = Coucou.Tertiary,
                    fontSize = 12.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        Text(ago(s.at), color = Coucou.Tertiary, fontSize = 12.sp)
    }
}

/** The card that needs an answer — approval buttons or question options. */
@Composable
private fun PendingPanel(card: Relay.Card?, sent: String?, vm: CoucouViewModel) {
    if (card == null || sent != null) {
        SentCard(sent ?: "allow")
        return
    }
    val tint = if (card.isQuestion) Coucou.Question else Coucou.Approval
    // Pop in like the island's card on the PC: the grow spring (response 0.5 s,
    // damping 0.72 — ~dampingRatio 0.72 at StiffnessLow), a plain jump when the
    // user asked for no animations. Each new requestId pops once.
    val resolver = LocalContext.current.contentResolver
    val reduced = remember {
        MotionSpec.isReduced(Settings.Global.getFloat(resolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f))
    }
    val pop = remember(card.requestId) { Animatable(if (reduced) 1f else 0.92f) }
    val fade = remember(card.requestId) { Animatable(if (reduced) 1f else 0f) }
    LaunchedEffect(card.requestId) {
        if (!reduced) {
            launch { pop.animateTo(1f, spring(0.72f, Spring.StiffnessLow)) }
            fade.animateTo(1f, tween(220))
        }
    }
    CoucouCard(tint = tint, wash = true, modifier = Modifier.fillMaxWidth().animateContentSize()
        .graphicsLayer { scaleX = pop.value; scaleY = pop.value; alpha = fade.value }) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            // The iOS banner row: agent tile, its name, then the waiting line
            // in the accent — "waiting for your OK".
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier
                        .size(34.dp)
                        .clip(RoundedCornerShape(10.dp))
                        .background(MochiSpec.tile(Color(0xFF4A4A4C))),
                    contentAlignment = Alignment.Center,
                ) {
                    Mochi(
                        if (card.isQuestion) MochiSpec.State.Question else MochiSpec.State.Approval,
                        Modifier.size(28.dp),
                        seed = card.requestId,
                    )
                }
                Spacer(Modifier.width(10.dp))
                Column {
                    Text(
                        card.agent,
                        color = Coucou.Ink,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        stringResource(if (card.isQuestion) R.string.card_needs_answer else R.string.card_waiting_ok),
                        color = tint,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            }
            if (card.title.isNotBlank()) {
                Text(card.title, color = Coucou.Ink, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
            }
            if (card.detail.isNotBlank()) {
                Text(
                    card.detail,
                    color = Coucou.Ink.copy(alpha = 0.92f),
                    fontFamily = FontFamily.Monospace,
                    fontSize = 13.sp,
                    maxLines = 6,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .background(Coucou.Field)
                        .padding(12.dp),
                )
            }
            if (!card.isQuestion) {
                ApprovalButtons(card, vm)
            } else {
                QuestionOptions(card, vm)
            }
        }
    }
}

@Composable
private fun ApprovalButtons(card: Relay.Card, vm: CoucouViewModel) {
    val context = LocalContext.current
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            PillButton(
                stringResource(R.string.deny),
                onClick = { vm.decide(card, "deny") },
                container = Coucou.DenyBg,
                ink = Coucou.DenyInk,
                modifier = Modifier.weight(1f),
            )
            // iOS' "Allow asks for Face ID" — Deny stays a plain tap.
            PillButton(
                stringResource(R.string.allow),
                onClick = { gateWithBiometrics(context) { vm.decide(card, "allow") } },
                container = Coucou.Allow,
                ink = Color.Black,
                modifier = Modifier.weight(1f),
            )
        }
        // The rule Claude Code offered — the same "Always allow …" the PC shows.
        card.alwaysLabel?.let { label ->
            PillButton(
                label,
                onClick = { gateWithBiometrics(context) { vm.decide(card, "always") } },
                container = Coucou.Panel2,
                ink = Coucou.Ink,
                modifier = Modifier.fillMaxWidth(),
            )
            card.alwaysDetail?.let {
                Text(it, color = Coucou.Tertiary, fontSize = 12.sp, modifier = Modifier.padding(horizontal = 4.dp))
            }
        }
        // "Reply in terminal" — nobody acts here, the agent asks there.
        Text(
            stringResource(R.string.card_reply_terminal),
            color = Coucou.Tertiary,
            fontSize = 13.sp,
            textAlign = TextAlign.Center,
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(8.dp))
                .clickable { vm.decide(card, "decline") }
                .padding(vertical = 8.dp),
        )
    }
}

@Composable
private fun QuestionOptions(card: Relay.Card, vm: CoucouViewModel) {
    val picked = remember(card.requestId) { mutableStateMapOf<String, List<String>>() }
    // question text → what was typed under "Other…" (blank/closed = not used)
    val other = remember(card.requestId) { mutableStateMapOf<String, String>() }
    val groups = card.questions.ifEmpty { listOf(Relay.Question(card.title, card.options)) }

    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        groups.forEach { q ->
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                if (q.q.isNotBlank() && q.q != card.title) {
                    Text(q.q, color = Coucou.Ink, fontSize = 15.sp, fontWeight = FontWeight.Medium)
                }
                q.options.forEach { opt ->
                    OptionRow(
                        label = opt,
                        selected = opt in picked[q.q].orEmpty(),
                        onClick = { picked[q.q] = QuestionAnswers.toggle(picked[q.q].orEmpty(), opt, q.multi) },
                        role = if (q.multi) Role.Checkbox else Role.RadioButton,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                // "Other…" — the row opens a field; the words are the answer.
                OptionRow(
                    label = stringResource(R.string.option_other),
                    selected = !other[q.q].isNullOrBlank(),
                    onClick = {
                        if (other.containsKey(q.q)) other.remove(q.q) else other[q.q] = ""
                    },
                    role = if (q.multi) Role.Checkbox else Role.RadioButton,
                    modifier = Modifier.fillMaxWidth(),
                )
                if (other.containsKey(q.q)) {
                    CoucouField(
                        value = other[q.q].orEmpty(),
                        onValueChange = { other[q.q] = it },
                        hint = stringResource(R.string.type_answer_hint),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
        }
        PillButton(
            stringResource(R.string.answer),
            onClick = {
                vm.decide(
                    card, "answer",
                    QuestionAnswers.toAnswers(groups, picked, other),
                    QuestionAnswers.others(groups, other),
                )
            },
            filled = true,
            enabled = QuestionAnswers.complete(groups, picked, other),
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

/** Decision went out — the card stays until the PC's next state confirms it. */
@Composable
private fun SentCard(decision: String) {
    CoucouCard(modifier = Modifier.fillMaxWidth()) {
        Row(
            Modifier.padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (decision == "allow") {
                DrawnCheckmark(34.dp)
            } else {
                Box(
                    Modifier
                        .size(30.dp)
                        .clip(CircleShape)
                        .background(Coucou.Error),
                    contentAlignment = Alignment.Center,
                ) { Text("✕", color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.Bold) }
            }
            Spacer(Modifier.width(12.dp))
            Text(
                stringResource(
                    when (decision) {
                        "allow" -> R.string.sent_allowed
                        "always" -> R.string.sent_always
                        "deny" -> R.string.sent_denied
                        "decline" -> R.string.sent_declined
                        else -> R.string.sent_answered
                    },
                ),
                color = if (decision == "deny") Coucou.Error else Coucou.Done,
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
            )
        }
    }
}

/** One live agent row — small Mochi in the agent's colour, name, one line, state dot. */
@Composable
private fun AgentRow(s: Relay.Session) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 64.dp)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            Modifier
                .size(40.dp)
                .clip(RoundedCornerShape(Coucou.CornerTile))
                .background(MochiSpec.tile(Color(s.color))),
            contentAlignment = Alignment.Center,
        ) {
            Mochi(MochiSpec.State.of(s.state), Modifier.size(34.dp), seed = s.pillId)
        }
        Column(Modifier.weight(1f)) {
            Text(
                agentTitle(s.agent),
                color = Coucou.Ink,
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                buildString {
                    append(s.statusText.ifBlank { s.state })
                    if (s.stepCount > 0) append(stringResource(R.string.agent_step, s.stepIndex, s.stepCount))
                },
                color = Coucou.Secondary,
                fontSize = 13.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        StateDot(Coucou.accentFor(s.state))
    }
}

// MARK: - Chat

@Composable
fun ChatScreen(vm: CoucouViewModel) {
    val state = vm.box?.state
    val sessions = state?.chatSessions.orEmpty()
    val selected = vm.selectedSession()
    // A picked Devin session shows its transcript; otherwise the island's chat.
    val lines = if (selected != null) state?.chatTranscript.orEmpty() else state?.chatTail.orEmpty()
    var draft by rememberSaveable { mutableStateOf("") }
    val listState = rememberLazyListState()
    // The transcript is capped at 40 lines: once full its size stays the same
    // while new lines arrive, so the newest line's text is part of the key.
    LaunchedEffect(lines.size, lines.lastOrNull()?.text) {
        if (lines.isNotEmpty()) listState.animateScrollToItem(lines.size - 1)
    }

    Column(
        Modifier
            .fillMaxSize()
            .safeDrawingPadding(),
    ) {
        // A tab now — no back arrow; the bar switches sections.
        Text(
            selected?.title?.ifBlank { stringResource(R.string.agent_session, agentTitle(selected.agent)) }
                ?: stringResource(R.string.nav_chat),
            color = Coucou.Ink,
            fontSize = 20.sp,
            fontWeight = FontWeight.Bold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(horizontal = 20.dp, vertical = 12.dp),
        )
        if (sessions.isNotEmpty()) {
            LazyRow(
                Modifier.fillMaxWidth(),
                contentPadding = PaddingValues(horizontal = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                item {
                    SessionChip(stringResource(R.string.app_name), selected == null) { vm.selectSession(null) }
                }
                items(sessions, key = { it.id }) { s ->
                    SessionChip(s.title.ifBlank { s.id }, s.id == selected?.id) { vm.selectSession(s) }
                }
            }
            Spacer(Modifier.height(8.dp))
        }
        // The iOS session header: tile + name + where it lives on disk.
        if (selected != null) {
            CoucouCard(modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
                Row(
                    Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(
                        Modifier
                            .size(34.dp)
                            .clip(RoundedCornerShape(10.dp))
                            .background(MochiSpec.tile(Color(0xFF4A4A4C))),
                        contentAlignment = Alignment.Center,
                    ) {
                        Mochi(MochiSpec.State.Idle, Modifier.size(28.dp), seed = selected.id)
                    }
                    Spacer(Modifier.width(10.dp))
                    Column(Modifier.weight(1f)) {
                        Text(
                            selected.title.ifBlank { stringResource(R.string.agent_session, agentTitle(selected.agent)) },
                            color = Coucou.Ink,
                            fontSize = 15.sp,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        if (selected.dir.isNotBlank()) {
                            Text(
                                selected.dir,
                                color = Coucou.Secondary,
                                fontSize = 12.sp,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                }
            }
            Spacer(Modifier.height(8.dp))
        }
        LazyColumn(
            Modifier
                .weight(1f)
                .fillMaxWidth(),
            state = listState,
            verticalArrangement = Arrangement.spacedBy(8.dp),
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
        ) {
            if (lines.isEmpty()) {
                item {
                    Column(
                        Modifier
                            .fillMaxWidth()
                            .padding(vertical = 40.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Mochi(MochiSpec.State.Idle, Modifier.size(56.dp), seed = "chat")
                        Spacer(Modifier.height(12.dp))
                        Text(
                            stringResource(
                                if (selected != null) R.string.chat_empty_transcript
                                else R.string.chat_empty,
                            ),
                            color = Coucou.Secondary,
                            fontSize = 14.sp,
                        )
                    }
                }
            }
            items(lines) { line ->
                if (line.name != null) {
                    // The iOS "What it did" row — tool card tinted by kind.
                    val tint = toolColor(line.name)
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Start) {
                        Row(
                            Modifier
                                .clip(RoundedCornerShape(10.dp))
                                .background(tint.copy(alpha = 0.13f))
                                .padding(horizontal = 10.dp, vertical = 6.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                line.name,
                                color = tint,
                                fontSize = 11.sp,
                                fontWeight = FontWeight.SemiBold,
                                fontFamily = FontFamily.Monospace,
                            )
                            if (line.text.isNotBlank()) {
                                Spacer(Modifier.width(8.dp))
                                Text(
                                    line.text,
                                    color = Coucou.Ink.copy(alpha = 0.75f),
                                    fontFamily = FontFamily.Monospace,
                                    fontSize = 11.sp,
                                    maxLines = 2,
                                    overflow = TextOverflow.Ellipsis,
                                    modifier = Modifier.weight(1f, fill = false),
                                )
                            }
                        }
                    }
                } else {
                    Row(
                        Modifier.fillMaxWidth(),
                        horizontalArrangement = if (line.isUser) Arrangement.End else Arrangement.Start,
                    ) {
                        Box(
                            Modifier
                                .clip(RoundedCornerShape(18.dp))
                                .background(if (line.isUser) Color.White else Coucou.Card)
                                .then(
                                    if (line.isUser) Modifier
                                    else Modifier.border(1.dp, Coucou.Line, RoundedCornerShape(18.dp))
                                )
                                .padding(horizontal = 14.dp, vertical = 10.dp),
                        ) {
                            Text(
                                line.text,
                                color = if (line.isUser) Color.Black else Coucou.Ink,
                                fontSize = 15.sp,
                            )
                        }
                    }
                }
            }
        }
        // The iOS quick bar: canned follow-ups straight into the session.
        if (selected != null) {
            val actions = listOf(
                stringResource(R.string.chat_action_continue),
                stringResource(R.string.chat_action_tests),
                stringResource(R.string.chat_action_fix),
                stringResource(R.string.chat_action_commit),
            )
            LazyRow(
                Modifier.fillMaxWidth(),
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 2.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items(actions) { action ->
                    Box(
                        Modifier
                            .clip(RoundedCornerShape(16.dp))
                            .background(Coucou.Panel2)
                            .border(1.dp, Coucou.Line, RoundedCornerShape(16.dp))
                            .clickable { vm.sendChat(action) }
                            .padding(horizontal = 12.dp, vertical = 7.dp),
                    ) {
                        Text(action, color = Coucou.Ink, fontSize = 13.sp)
                    }
                }
            }
        }
        Row(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            CoucouField(
                value = draft,
                onValueChange = { draft = it },
                hint = if (selected != null) stringResource(R.string.chat_hint_session, agentTitle(selected.agent))
                else stringResource(R.string.chat_hint),
                modifier = Modifier.weight(1f),
            )
            Spacer(Modifier.width(10.dp))
            Box(
                Modifier
                    .size(42.dp)
                    .clip(CircleShape)
                    .background(if (draft.isBlank()) Coucou.Panel2 else Color.White)
                    .clickable(enabled = draft.isNotBlank()) {
                        vm.sendChat(draft)
                        draft = ""
                    },
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.AutoMirrored.Filled.Send,
                    contentDescription = stringResource(R.string.send),
                    tint = if (draft.isBlank()) Coucou.Tertiary else Color.Black,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
    }
}

// MARK: - Picker

/** Every chat one CLI has on this PC — tap to open and continue it.
 *  The title is the agent dropdown: switch which CLI's history is listed. */
@Composable
fun PickerScreen(vm: CoucouViewModel) {
    val all = vm.box?.state?.chatSessions.orEmpty()
    val agents = remember(all) { all.map { it.agent }.distinct().sorted() }
    val sessions = all.filter { it.agent == vm.pickerAgent }.sortedByDescending { it.at }
    var agentMenu by remember { mutableStateOf(false) }
    Column(
        Modifier
            .fillMaxSize()
            .safeDrawingPadding(),
    ) {
        Row(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 4.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = { vm.navigate(CoucouViewModel.Screen.HOME) }) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.back), tint = Coucou.Ink)
            }
            Box {
                Row(
                    Modifier
                        .clip(RoundedCornerShape(12.dp))
                        .clickable { agentMenu = true }
                        .padding(horizontal = 8.dp, vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        agentTitle(vm.pickerAgent),
                        color = Coucou.Ink,
                        fontSize = 20.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Icon(
                        Icons.Filled.ArrowDropDown,
                        contentDescription = stringResource(R.string.switch_agent),
                        tint = Coucou.Secondary,
                    )
                }
                DropdownMenu(
                    expanded = agentMenu,
                    onDismissRequest = { agentMenu = false },
                    containerColor = Coucou.Card,
                ) {
                    agents.forEach { a ->
                        DropdownMenuItem(
                            text = {
                                Text(
                                    agentTitle(a),
                                    color = if (a == vm.pickerAgent) Coucou.Ink else Coucou.Secondary,
                                    fontWeight = if (a == vm.pickerAgent) FontWeight.SemiBold else FontWeight.Normal,
                                )
                            },
                            onClick = {
                                vm.pickAgent(a)
                                agentMenu = false
                            },
                        )
                    }
                }
            }
        }
        LazyColumn(
            Modifier
                .fillMaxWidth()
                .weight(1f),
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
        ) {
            if (sessions.isEmpty()) {
                item {
                    Text(
                        stringResource(
                            R.string.picker_empty,
                            if (vm.pickerAgent == "claude") "claude" else vm.pickerAgent,
                        ),
                        color = Coucou.Secondary,
                        fontSize = 14.sp,
                        modifier = Modifier.padding(vertical = 24.dp),
                    )
                }
            }
            items(sessions, key = { it.id }) { s ->
                CliSessionRow(
                    s,
                    onClick = {
                        vm.selectSession(s)
                        vm.navigate(CoucouViewModel.Screen.CHAT)
                    },
                )
                RowDivider()
            }
        }
    }
}

/** One conversation chip above the chat — the island's own or a CLI session. */
@Composable
private fun SessionChip(label: String, active: Boolean, onClick: () -> Unit) {
    Box(
        Modifier
            .clip(RoundedCornerShape(20.dp))
            .background(if (active) Color.White else Coucou.Panel2)
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 8.dp),
    ) {
        Text(
            label,
            color = if (active) Color.Black else Coucou.Secondary,
            fontSize = 13.sp,
            fontWeight = if (active) FontWeight.SemiBold else FontWeight.Normal,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

// MARK: - Bottom navigation

/**
 * The upstream floating bar: a black pill hanging over the screen's bottom
 * edge, icons + labels always shown, the open tab lit with a lighter pill,
 * an amber dot on Home while a request waits for you.
 */
@Composable
fun CoucouNavBar(vm: CoucouViewModel) {
    data class Tab(val screen: CoucouViewModel.Screen, val label: String, val icon: androidx.compose.ui.graphics.vector.ImageVector)
    val tabs = listOf(
        Tab(CoucouViewModel.Screen.HOME, stringResource(R.string.nav_home), Icons.Filled.Home),
        Tab(CoucouViewModel.Screen.CHAT, stringResource(R.string.nav_chat), Icons.AutoMirrored.Filled.Send),
        Tab(CoucouViewModel.Screen.SETTINGS, stringResource(R.string.nav_settings), Icons.Filled.Settings),
    )
    val alert = vm.box?.pending?.takeUnless { vm.isAnswered(it.requestId) } != null
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 24.dp, vertical = 12.dp)
            .heightIn(min = 64.dp)
            .clip(CircleShape)
            .background(Coucou.Card)
            .border(1.dp, Coucou.Line, CircleShape)
            .padding(6.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        tabs.forEach { tab ->
            val on = vm.screen == tab.screen
            Box(
                Modifier
                    .weight(1f)
                    .heightIn(min = 52.dp)
                    .clip(CircleShape)
                    .background(if (on) Coucou.Panel2 else Color.Transparent)
                    .clickable(role = Role.Tab) { vm.navigate(tab.screen) },
                contentAlignment = Alignment.Center,
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(
                        tab.icon,
                        contentDescription = tab.label,
                        tint = if (on) Coucou.Ink else Coucou.Tertiary,
                        modifier = Modifier.size(22.dp),
                    )
                    Text(
                        tab.label,
                        color = if (on) Coucou.Ink else Coucou.Tertiary,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        softWrap = false,
                    )
                }
                if (alert && tab.screen == CoucouViewModel.Screen.HOME) {
                    Box(
                        Modifier
                            .align(Alignment.TopCenter)
                            .padding(start = 26.dp, top = 2.dp)
                            .size(9.dp)
                            .clip(CircleShape)
                            .background(Coucou.Approval)
                            .border(2.dp, Coucou.Card, CircleShape),
                    )
                }
            }
        }
    }
}

// MARK: - Settings

/** Pairing, Mochi's wardrobe and the phone's own info — what used to crowd Home's footer. */
@Composable
fun SettingsScreen(vm: CoucouViewModel) {
    Column(
        Modifier
            .fillMaxSize()
            .safeDrawingPadding()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp),
    ) {
        Text(
            stringResource(R.string.settings_title),
            fontSize = 22.sp,
            fontWeight = FontWeight.Bold,
            color = Coucou.Ink,
            modifier = Modifier.padding(top = 12.dp, bottom = 14.dp, start = 4.dp),
        )

        // Mochi — the wardrobe, with a live preview of the current pick.
        SectionLabel("Mochi")
        CoucouCard(modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        Modifier
                            .size(64.dp)
                            .clip(RoundedCornerShape(16.dp))
                            .background(Coucou.Field),
                        contentAlignment = Alignment.Center,
                    ) {
                        Mochi(
                            MochiSpec.State.Idle,
                            Modifier.size(52.dp),
                            seed = "settings",
                            outfit = Wardrobe.resolve(vm.outfitSel, LocalDate.now()),
                        )
                    }
                    Spacer(Modifier.width(14.dp))
                    Column {
                        Text(stringResource(R.string.wardrobe), color = Coucou.Ink, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                        Text(
                            wardrobeLabel(vm.outfitSel),
                            color = Coucou.Secondary,
                            fontSize = 14.sp,
                        )
                    }
                }
                Spacer(Modifier.height(14.dp))
                Wardrobe.SELECTIONS.chunked(4).forEach { row ->
                    Row(Modifier.fillMaxWidth()) {
                        row.forEach { sel ->
                            val on = sel == vm.outfitSel
                            Column(
                                Modifier
                                    .weight(1f)
                                    .clip(RoundedCornerShape(12.dp))
                                    .clickable { vm.setOutfit(sel) }
                                    .padding(vertical = 8.dp),
                                horizontalAlignment = Alignment.CenterHorizontally,
                            ) {
                                Box(
                                    Modifier
                                        .size(44.dp)
                                        .clip(RoundedCornerShape(12.dp))
                                        .background(if (on) Coucou.Panel2 else Color.Transparent)
                                        .then(
                                            if (on) Modifier.border(1.dp, Coucou.Line, RoundedCornerShape(12.dp))
                                            else Modifier
                                        )
                                        .padding(4.dp),
                                    contentAlignment = Alignment.Center,
                                ) {
                                    Mochi(
                                        MochiSpec.State.Idle,
                                        Modifier.size(36.dp),
                                        seed = sel,
                                        outfit = Wardrobe.resolve(sel, LocalDate.now()),
                                    )
                                }
                                Text(
                                    wardrobeLabel(sel),
                                    color = if (on) Coucou.Ink else Coucou.Tertiary,
                                    fontSize = 10.sp,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                        }
                        repeat(4 - row.size) { Spacer(Modifier.weight(1f)) }
                    }
                }
            }
        }

        // This phone — the relay it talks to and the name it gave the PC.
        SectionLabel(stringResource(R.string.settings_this_phone))
        CoucouCard(modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.padding(horizontal = 14.dp)) {
                SettingsRow(stringResource(R.string.settings_relay), vm.worker.ifBlank { "—" })
                Hairline()
                SettingsRow(stringResource(R.string.settings_name), Prefs.load(LocalContext.current)?.deviceName ?: Build.MODEL)
            }
        }

        // Danger zone — a pairing cannot be restored from the phone, so
        // unpairing asks first.
        var confirmUnpair by remember { mutableStateOf(false) }
        Spacer(Modifier.height(18.dp))
        CoucouCard(modifier = Modifier.fillMaxWidth()) {
            Text(
                stringResource(R.string.unpair_phone),
                color = Coucou.Error,
                fontSize = 15.sp,
                fontWeight = FontWeight.Medium,
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(Coucou.CornerCard))
                    .clickable { confirmUnpair = true }
                    .padding(16.dp),
            )
        }
        if (confirmUnpair) {
            AlertDialog(
                onDismissRequest = { confirmUnpair = false },
                containerColor = Coucou.Card,
                title = { Text(stringResource(R.string.unpair_confirm_title), color = Coucou.Ink) },
                text = {
                    Text(
                        stringResource(R.string.unpair_confirm_body),
                        color = Coucou.Secondary,
                    )
                },
                confirmButton = {
                    TextButton(onClick = {
                        confirmUnpair = false
                        vm.unpair()
                    }) { Text(stringResource(R.string.unpair), color = Coucou.Error) }
                },
                dismissButton = {
                    TextButton(onClick = { confirmUnpair = false }) {
                        Text(stringResource(R.string.cancel), color = Coucou.Secondary)
                    }
                },
            )
        }
        Spacer(Modifier.height(32.dp))
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text,
        color = Coucou.Tertiary,
        fontSize = 13.sp,
        modifier = Modifier.padding(start = 4.dp, top = 14.dp, bottom = 8.dp),
    )
}

@Composable
private fun SettingsRow(label: String, value: String) {
    Row(
        Modifier
            .fillMaxWidth()
            .padding(vertical = 13.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, color = Coucou.Secondary, fontSize = 15.sp)
        Spacer(Modifier.weight(1f))
        Text(
            value,
            color = Coucou.Tertiary,
            fontSize = 14.sp,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(start = 16.dp),
        )
    }
}

@Composable
private fun Hairline() = RowDivider()
