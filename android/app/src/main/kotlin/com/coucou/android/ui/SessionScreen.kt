package com.coucou.android.ui

import android.os.SystemClock
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import com.coucou.android.core.HomeText
import com.coucou.android.core.IconKind
import com.coucou.android.core.TypeScale
import com.coucou.android.mochi.MochiConst
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.coucou.android.R
import com.coucou.android.app.AppModel
import com.coucou.android.core.HomePanel
import com.coucou.android.core.Pills
import com.coucou.android.core.ToolLabels
import com.coucou.android.mochi.BotState
import com.coucou.android.mochi.MochiEngine
import com.coucou.android.mochi.MochiView

/**
 * One agent in detail, from what the computer sends with "Show session details on the phone": the project's
 * folder name, how far it got, the last message and the steps it took (newest first, in plain words).
 * Without that switch there is nothing to show but a hint on where to turn it on.
 */
@Composable
fun SessionScreen(model: AppModel, pillId: String, onBack: () -> Unit) {
    val s = model.sessions.firstOrNull { it.pillId == pillId }
    val clock = remember { { SystemClock.elapsedRealtimeNanos() / 1e6 } }
    val engine = remember(pillId) { MochiEngine(clock) }
    if (s == null) {
        Column(Modifier.fillMaxSize().padding(horizontal = Gutter)) {
            ScreenTitle(stringResource(R.string.session_details), onBack)
            Text(stringResource(R.string.session_ended), Modifier.padding(Gutter), style = TypeScale.BODY.style(tokens().textDim.c()))
        }
        return
    }
    if (engine.state != s.state) engine.setState(s.state)
    // Its own colour, like on Home: the Mochi's body, the glow's state colour stays Louis's.
    engine.bodyColor = HomePanel.colorHex(s)?.let { HomePanel.rgb(it) }
    val name = s.agent.ifBlank { Pills.byId(s.pillId)?.name.orEmpty() }
    val accent = HomePanel.colorHex(s)?.let { HomePanel.rgb(it) }?.let(::rgbColor) ?: tokens().text.c()
    val t = tokens()
    val busy = s.state == BotState.WORKING || s.state == BotState.THINKING || s.state == BotState.SEARCHING

    LazyColumn(Modifier.fillMaxSize().padding(horizontal = Gutter), verticalArrangement = Arrangement.spacedBy(Gap)) {
        item { ScreenTitle(name, onBack) }
        item {
            Panel(wash = MochiConst.STATES[s.state]?.color?.let(::rgbColor)) {
                Row(Modifier.padding(Gutter), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Gutter)) {
                    MochiView(engine, Modifier.size(96.dp))
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(
                            HomeText.line(s) ?: stringResource(stateLabel(s.state)), style = TypeScale.HEADLINE.style(t.text.c()),
                            maxLines = 3, overflow = TextOverflow.Ellipsis,
                        )
                        s.project?.let { Chip(stringResource(R.string.session_project, it)) }
                    }
                }
            }
        }
        if (!s.finalLine.isNullOrBlank()) {
            item { SectionHeading(stringResource(R.string.session_last)) }
            item {
                Panel(wash = MochiConst.STATES[BotState.FINISHED]?.color?.let(::rgbColor)) {
                    SelectionContainer { Text(s.finalLine, Modifier.padding(Gutter), style = TypeScale.BODY.style(t.text.c())) }
                }
            }
        }
        if (s.files.isNotEmpty()) {
            item { SectionHeading(stringResource(R.string.files_heading)) }
            item {
                Panel {
                    // Newest change first, like the steps.
                    s.files.asReversed().forEachIndexed { i, f ->
                        if (i > 0) RowDivider()
                        ListRow(
                            f.name, hint = if (f.isNew) stringResource(R.string.files_new) else null,
                            onClick = { model.openDiff(s.pillId, f) },
                            trailing = {
                                Text(
                                    stringResource(R.string.files_counts, f.added, f.removed), maxLines = 1,
                                    style = TypeScale.SECONDARY.style(t.textDim.c()).copy(fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace),
                                )
                            },
                        )
                    }
                }
            }
        }
        item { SectionHeading(stringResource(R.string.session_steps)) }
        val steps = HomePanel.stepsNewestFirst(s)
        if (steps.isEmpty()) {
            item {
                Panel {
                    Text(
                        stringResource(if (model.detailsOffered) R.string.session_no_steps else R.string.session_hint),
                        Modifier.padding(Gutter), style = TypeScale.SECONDARY.style(t.textDim.c()),
                    )
                }
            }
        } else {
            item {
                Panel {
                    SelectionContainer {
                        Column {
                            steps.forEachIndexed { i, step ->
                                if (i > 0) RowDivider()
                                val current = i == 0 && busy
                                Row(
                                    Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(horizontal = Gutter, vertical = 10.dp),
                                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
                                ) {
                                    // Done steps carry a check; the one being worked on carries the agent's dot.
                                    if (current) StateDot(accent, Modifier.padding(horizontal = 7.dp))
                                    else CoucouIcon(IconKind.CHECK, tint = if (i == 0) StatusColors.online else t.textFaint.c(), size = 22.dp)
                                    // Free text is never shown (it can hold a command or a path), so a step the label cannot name
                                    // gets a neutral word instead of an empty row.
                                    Text(
                                        ToolLabels.label(step).ifEmpty {
                                            stringResource(if (current) R.string.session_step_working else R.string.session_step_done)
                                        },
                                        Modifier.weight(1f),
                                        style = TypeScale.BODY.style(if (i == 0) t.text.c() else t.textDim.c()).copy(fontWeight = if (current) FontWeight.SemiBold else FontWeight.Normal),
                                        maxLines = 4, overflow = TextOverflow.Ellipsis,
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
        item { Spacer(Modifier.height(Gutter)) }
    }
}
