package fr.louisraille.coucou.phone

import android.os.Build
import androidx.compose.animation.animateContentSize
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
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

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
        Text("Coucou", fontSize = 28.sp, fontWeight = FontWeight.Bold, color = Coucou.Ink)
        Text(
            "Approve your PC's agent cards from here.",
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
            hint = "Pairing code — id|secret|worker",
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(10.dp))
        CoucouField(
            value = worker,
            onValueChange = { worker = it },
            hint = "Relay URL — https://….workers.dev",
            keyboardType = KeyboardType.Uri,
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(10.dp))
        CoucouField(
            value = name,
            onValueChange = { name = it },
            hint = "This phone's name",
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
            text = if (vm.busy) "Connecting…" else "Connect",
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

    Column(
        Modifier
            .fillMaxSize()
            .safeDrawingPadding()
            .padding(horizontal = 16.dp),
    ) {
        // Top bar — wordmark + chat entry, quiet like iOS' navigationTitle row.
        Row(
            Modifier
                .fillMaxWidth()
                .padding(top = 10.dp, bottom = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Coucou", fontSize = 22.sp, fontWeight = FontWeight.Bold, color = Coucou.Ink)
            Spacer(Modifier.weight(1f))
        }

        PullToRefreshBox(
            isRefreshing = vm.refreshing,
            onRefresh = { vm.refreshNow() },
            modifier = Modifier.weight(1f),
        ) {
            LazyColumn(
                Modifier.fillMaxSize(),
                verticalArrangement = Arrangement.spacedBy(10.dp),
                contentPadding = PaddingValues(bottom = 16.dp),
            ) {
                // The island — lead Mochi + what needs you, card grows under it.
                item {
                    IslandHeader(
                        box = box,
                        pending = card,
                        sent = sent,
                        lineError = vm.lineError,
                    )
                }

                if (card != null || sent != null) {
                    item { PendingPanel(card = card, sent = sent, vm = vm) }
                }

                // What's on the PC right now — the island chat sits first,
                // the live agents card right under it.
                item {
                    ChatEntryCard(
                        tail = box?.state?.chatTail.orEmpty(),
                        onOpen = { vm.navigate(CoucouViewModel.Screen.CHAT) },
                    )
                }

                if (sessions.isNotEmpty()) {
                    // The iOS grouped list: one card, rows split by hairlines.
                    item {
                        CoucouCard(modifier = Modifier.fillMaxWidth()) {
                            Column(Modifier.padding(horizontal = 14.dp, vertical = 6.dp)) {
                                sessions.forEachIndexed { i, s ->
                                    SessionRow(s)
                                    if (i < sessions.size - 1) {
                                        Box(
                                            Modifier
                                                .fillMaxWidth()
                                                .height(0.5.dp)
                                                .padding(start = 52.dp)
                                                .background(Coucou.Hairline),
                                        )
                                    }
                                }
                            }
                        }
                    }
                }

                // One section per CLI — each opens its full chat history.
                box?.state?.chatSessions.orEmpty()
                    .groupBy { it.agent }
                    .toSortedMap()
                    .forEach { (agent, list) ->
                        item {
                            AgentSection(
                                agent = agent,
                                sessions = list.sortedByDescending { it.at },
                                onPick = { s -> vm.selectSession(s); vm.navigate(CoucouViewModel.Screen.CHAT) },
                                onAll = { vm.openPicker(agent) },
                            )
                        }
                    }

                if (sessions.isEmpty() && card == null) {
                    item { EmptyCard(box != null) }
                }

                item {
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .padding(top = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            vm.worker,
                            fontSize = 12.sp,
                            color = Coucou.Tertiary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f),
                        )
                        Text(
                            "Unpair",
                            color = Coucou.Error.copy(alpha = 0.8f),
                            fontSize = 13.sp,
                            modifier = Modifier
                                .clip(CircleShape)
                                .clickable { vm.unpair() }
                                .padding(horizontal = 10.dp, vertical = 6.dp),
                        )
                    }
                }
            }
        }
    }
}

/** The black island: the lead session's Mochi, a headline, what's going on. */
@Composable
private fun IslandHeader(
    box: Relay.Fetch?,
    pending: Relay.Card?,
    sent: String?,
    lineError: String?,
) {
    val lead = remember(box) {
        box?.state?.sessions.orEmpty().maxByOrNull { urgencyOf(it.state) }
    }
    val leadState = when {
        pending != null -> if (pending.isQuestion) MochiSpec.State.Question else MochiSpec.State.Approval
        lead != null -> MochiSpec.State.of(lead.state)
        else -> MochiSpec.State.Sleeping
    }
    val headline = when {
        lineError != null -> "Can't reach the relay"
        sent != null -> if (sent == "allow") "Allowed" else "Sent"
        pending != null -> "${pending.agent} needs you"
        sessionsSummary(box) != null -> sessionsSummary(box)!!
        box == null -> "Waiting for your PC…"
        else -> "All quiet"
    }
    val detail = when {
        lineError != null -> lineError
        pending != null -> pending.title.ifBlank { null }
        lead != null -> "${lead.agent} · ${lead.statusText.ifBlank { lead.state }}"
        else -> null
    }

    CoucouCard(cornerRadius = Coucou.CornerIsland, modifier = Modifier.fillMaxWidth()) {
        Box(
            Modifier
                .fillMaxWidth()
                .background(Coucou.CardSoft)
                .padding(horizontal = 18.dp, vertical = 14.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Mochi(leadState, Modifier.size(52.dp), seed = pending?.requestId ?: lead?.pillId ?: "idle")
                Spacer(Modifier.width(14.dp))
                Column {
                    Text(headline, color = Coucou.Ink, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                    if (detail != null) {
                        Text(
                            detail,
                            color = if (lineError != null) Coucou.Error else Coucou.Secondary,
                            fontSize = 14.sp,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
        }
    }
}

private fun sessionsSummary(box: Relay.Fetch?): String? {
    val sessions = box?.state?.sessions.orEmpty()
    if (sessions.isEmpty()) return null
    val working = sessions.count { it.state == "working" || it.state == "thinking" }
    return when {
        working > 0 -> if (sessions.size == 1) "${sessions[0].agent} is working" else "$working agents working"
        else -> "${sessions.size} session${if (sessions.size > 1) "s" else ""}"
    }
}

private fun urgencyOf(state: String): Int = when (state) {
    "approval" -> 5; "question" -> 4; "error" -> 3
    "working" -> 2; "thinking" -> 2; "searching" -> 2; "ratelimit" -> 2
    "finished" -> 1; else -> 0
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
private fun ago(at: Long): String {
    if (at <= 0) return ""
    val s = System.currentTimeMillis() / 1000 - at
    return when {
        s < 60 -> "now"
        s < 3600 -> "${s / 60}m"
        s < 86400 -> "${s / 3600}h"
        else -> "${s / 86400}d"
    }
}

/** The island's own chat — first card under the island header. */
@Composable
private fun ChatEntryCard(tail: List<Relay.ChatLine>, onOpen: () -> Unit) {
    val preview = tail.lastOrNull()?.text.orEmpty()
    CoucouCard(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(Coucou.CornerCard))
            .clickable(onClick = onOpen),
    ) {
        Row(
            Modifier.padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier
                    .size(40.dp)
                    .clip(RoundedCornerShape(Coucou.CornerTile))
                    .background(MochiSpec.tile(Color(0xFF4A4A4C))),
                contentAlignment = Alignment.Center,
            ) {
                Mochi(MochiSpec.State.Idle, Modifier.size(34.dp), seed = "coucou-chat")
            }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text("Chat", color = Coucou.Ink, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                Text(
                    preview.ifBlank { "The chat living on your PC" },
                    color = Coucou.Secondary,
                    fontSize = 14.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Text("›", color = Coucou.Tertiary, fontSize = 22.sp)
        }
    }
}

/** One agent's section on Home: header + its three newest CLI sessions. */
@Composable
private fun AgentSection(
    agent: String,
    sessions: List<Relay.ChatSession>,
    onPick: (Relay.ChatSession) -> Unit,
    onAll: () -> Unit,
) {
    Column {
        Row(
            Modifier
                .fillMaxWidth()
                .padding(start = 4.dp, bottom = 6.dp, top = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                agentTitle(agent),
                color = Coucou.Secondary,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
            )
            Text(
                "All ${sessions.size} ›",
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
                sessions.take(3).forEachIndexed { i, s ->
                    CliSessionRow(s, onClick = { onPick(s) })
                    if (i < sessions.take(3).size - 1) {
                        Box(
                            Modifier
                                .fillMaxWidth()
                                .height(0.5.dp)
                                .background(Coucou.Hairline),
                        )
                    }
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
    CoucouCard(tint = tint, modifier = Modifier.fillMaxWidth().animateContentSize()) {
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
                        if (card.isQuestion) "needs an answer" else "waiting for your OK",
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
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        PillButton(
            "Deny",
            onClick = { vm.decide(card, "deny") },
            container = Coucou.DenyBg,
            ink = Coucou.DenyInk,
            modifier = Modifier.weight(1f),
        )
        // iOS' "Allow asks for Face ID" — Deny stays a plain tap.
        PillButton(
            "Allow",
            onClick = { gateWithBiometrics(context) { vm.decide(card, "allow") } },
            container = Coucou.Allow,
            ink = Color.Black,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun QuestionOptions(card: Relay.Card, vm: CoucouViewModel) {
    val answers = remember(card.requestId) { mutableStateMapOf<String, String>() }
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
                        selected = answers[q.q] == opt,
                        onClick = { answers[q.q] = opt },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
        }
        PillButton(
            "Answer",
            onClick = { vm.decide(card, "answer", answers.toMap()) },
            filled = true,
            enabled = groups.all { answers[it.q] != null },
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
                if (decision == "allow") "Allowed — sent to your PC"
                else if (decision == "deny") "Denied — sent to your PC"
                else "Answered — sent to your PC",
                color = if (decision == "deny") Coucou.Error else Coucou.Done,
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
            )
        }
    }
}

@Composable
private fun SessionRow(s: Relay.Session) {
    Row(
        Modifier
            .fillMaxWidth()
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // The Mochi tile — white bot on the agent's colour, like iOS.
        Box(
            Modifier
                .size(40.dp)
                .clip(RoundedCornerShape(Coucou.CornerTile))
                .background(MochiSpec.tile(Color(s.color))),
            contentAlignment = Alignment.Center,
        ) {
            Mochi(MochiSpec.State.of(s.state), Modifier.size(34.dp), seed = s.pillId)
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(
                s.agent,
                color = Coucou.Ink,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (s.statusText.isNotBlank() && s.statusText != s.state) {
                Text(
                    s.statusText,
                    color = Coucou.Secondary,
                    fontSize = 14.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        Spacer(Modifier.width(8.dp))
        Column(horizontalAlignment = Alignment.End) {
            Text(
                s.state,
                color = Coucou.accentFor(s.state),
                fontSize = 14.sp,
                fontWeight = if (urgencyOf(s.state) >= 4) FontWeight.SemiBold else FontWeight.Normal,
            )
            if (s.stepCount > 0) {
                Text(
                    "step ${s.stepIndex}/${s.stepCount}",
                    color = Coucou.Tertiary,
                    fontSize = 11.sp,
                )
            }
        }
    }
}

@Composable
private fun EmptyCard(connected: Boolean) {
    CoucouCard(modifier = Modifier.fillMaxWidth()) {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(28.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Mochi(MochiSpec.State.Sleeping, Modifier.size(56.dp), seed = "empty")
            Spacer(Modifier.height(12.dp))
            Text(
                if (connected) "Nothing is running on your PC" else "Waiting for the PC's first update…",
                color = Coucou.Secondary,
                fontSize = 14.sp,
            )
        }
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
    LaunchedEffect(lines.size) {
        if (lines.isNotEmpty()) listState.animateScrollToItem(lines.size - 1)
    }

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
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = Coucou.Ink)
            }
            Text(
                selected?.title?.ifBlank { "${agentTitle(selected.agent)} session" } ?: "Chat",
                color = Coucou.Ink,
                fontSize = 20.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (sessions.isNotEmpty()) {
            LazyRow(
                Modifier.fillMaxWidth(),
                contentPadding = PaddingValues(horizontal = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                item {
                    SessionChip("Coucou", selected == null) { vm.selectSession(null) }
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
                            selected.title.ifBlank { "${agentTitle(selected.agent)} session" },
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
                            if (selected != null) "This session's transcript is empty — say hi."
                            else "No chat yet — the PC's last lines appear here.",
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
            LazyRow(
                Modifier.fillMaxWidth(),
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 2.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items(listOf("Continue", "Run the tests", "Fix the errors", "Commit")) { action ->
                    Box(
                        Modifier
                            .clip(RoundedCornerShape(16.dp))
                            .background(Coucou.Pill)
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
                hint = if (selected != null) "Continue this ${agentTitle(selected.agent)} session…"
                else "Message the PC…",
                modifier = Modifier.weight(1f),
            )
            Spacer(Modifier.width(10.dp))
            Box(
                Modifier
                    .size(42.dp)
                    .clip(CircleShape)
                    .background(if (draft.isBlank()) Coucou.Pill else Color.White)
                    .clickable(enabled = draft.isNotBlank()) {
                        vm.sendChat(draft)
                        draft = ""
                    },
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.AutoMirrored.Filled.Send,
                    contentDescription = "Send",
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
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = Coucou.Ink)
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
                        contentDescription = "Switch agent",
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
                        "No chats yet — run ${
                            if (vm.pickerAgent == "claude") "claude" else vm.pickerAgent
                        } on your PC first.",
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
                Box(
                    Modifier
                        .fillMaxWidth()
                        .height(0.5.dp)
                        .background(Coucou.Hairline),
                )
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
            .background(if (active) Color.White else Coucou.Pill)
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
