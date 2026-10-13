package com.coucou.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.border
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.coucou.android.R
import com.coucou.android.core.Decision
import com.coucou.android.core.HistoryDays
import com.coucou.android.core.HomePanel
import com.coucou.android.core.HomeText
import com.coucou.android.core.IconKind
import com.coucou.android.core.IslandSurface
import com.coucou.android.core.Pills
import com.coucou.android.core.Spacing
import com.coucou.android.core.TypeScale
import com.coucou.android.link.SessionInfo
import com.coucou.android.mochi.BotState
import com.coucou.android.mochi.MochiConst
import com.coucou.android.mochi.MochiEngine
import com.coucou.android.mochi.MochiView
import com.coucou.android.mochi.Rgb
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

internal fun stateLabel(state: BotState): Int = when (state) {
    BotState.IDLE -> R.string.state_ready
    BotState.WORKING -> R.string.state_working
    BotState.THINKING -> R.string.state_thinking
    BotState.SEARCHING -> R.string.state_searching
    BotState.APPROVAL -> R.string.state_approval
    BotState.QUESTION -> R.string.state_question
    BotState.ERROR -> R.string.state_error
    BotState.FINISHED -> R.string.state_finished
    BotState.RATELIMIT -> R.string.state_ratelimit
    BotState.SLEEPING -> R.string.state_sleeping
    BotState.DIZZY -> R.string.state_dizzy
}

internal fun rgbColor(c: Rgb) = Color(c.r.toFloat(), c.g.toFloat(), c.b.toFloat())


/** The colour of an agent's state (Louis's state colours), for dots and glows. */
internal fun stateColor(state: BotState): Color =
    if (state == BotState.IDLE) StatusColors.online else MochiConst.STATES[state]?.color?.let(::rgbColor) ?: StatusColors.offline

/**
 * The hero of Home: Louis's island grown to full width and hanging from the top edge of the screen. It
 * holds the agent that matters most, with its own Mochi in its own colour (the one you chose on the
 * computer), its name, one plain sentence, and at most two buttons. Black, with a soft
 * glow in the state's colour. No step counter: the computer cannot know how many steps are left.
 */
@Composable
fun HeroCard(
    focus: SessionInfo?, engine: MochiEngine, touch: Modifier, link: HomePanel.Link, running: Int,
    linkDot: Color, linkText: String, onLink: () -> Unit, onDetails: (() -> Unit)?,
    /** Opens the question sheet; non-null only while the agent has a question. */
    onQuestion: (() -> Unit)? = null,
    /** The phone can answer this question here (the `answers` capability): the button says so. */
    canAnswer: Boolean = false,
) {
    val state = focus?.state ?: BotState.SLEEPING
    val wash = MochiConst.STATES[state]?.color?.let(::rgbColor)
    val dim = Color(IslandSurface.TEXT_DIM)
    val white = Color(IslandSurface.TEXT)
    HeroPanel(wash = wash) {
        Column(
            Modifier.windowInsetsPadding(WindowInsets.statusBars).padding(start = Spacing.INSIDE.dp, end = Spacing.INSIDE.dp, top = 12.dp, bottom = 18.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                StateDot(linkDot)
                Spacer(Modifier.width(8.dp))
                Text(linkText, Modifier.weight(1f), style = TypeScale.LABEL.style(dim), maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (running > 0) Text(stringResource(R.string.home_running, running), style = TypeScale.LABEL.style(dim), maxLines = 1)
            }
            if (focus == null) {
                Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    MochiView(engine, Modifier.size(112.dp).then(touch))
                    Text(stringResource(R.string.home_empty_title), style = TypeScale.TITLE.style(white))
                    Text(stringResource(R.string.home_empty_hint), style = TypeScale.SECONDARY.style(dim), maxLines = 3)
                }
            } else {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    MochiView(engine, Modifier.size(108.dp).then(touch))
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        val pillName = Pills.byId(focus.pillId)?.name.orEmpty()
                        val name = focus.agent.ifBlank { pillName }.ifBlank { stringResource(R.string.app_name) }
                        Text(name, style = TypeScale.TITLE.style(white), maxLines = 2, overflow = TextOverflow.Ellipsis)
                        Text(
                            if (pillName.isNotBlank() && pillName != name) pillName else stringResource(R.string.agent_kind),
                            style = TypeScale.SECONDARY.style(dim), maxLines = 1, overflow = TextOverflow.Ellipsis,
                        )
                        Text(
                            HomeText.line(focus) ?: stringResource(stateLabel(state)), Modifier.padding(top = 4.dp),
                            style = TypeScale.HEADLINE.style(white), maxLines = 3, overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
            if (link != HomePanel.Link.NONE || onDetails != null || onQuestion != null) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (link != HomePanel.Link.NONE) {
                        PillButton(
                            stringResource(if (link == HomePanel.Link.PAIR) R.string.link_pair else R.string.link_approval), onLink,
                            kind = PillKind.PRIMARY, onDark = true,
                        )
                    }
                    if (onQuestion != null) PillButton(stringResource(if (canAnswer) R.string.question_see_answer else R.string.question_see), onQuestion, kind = PillKind.PRIMARY, onDark = true)
                    if (onDetails != null) {
                        PillButton(
                            stringResource(R.string.session_details), onDetails, onDark = true,
                            icon = { CoucouIcon(IconKind.CHEVRON, tint = white, size = 18.dp) },
                        )
                    }
                }
            }
        }
    }
}

/** The other agents, one full-width row each: its small Mochi in its colour, its name and one plain line. Tap to make it the main one. */
@Composable
fun AgentRows(others: List<SessionInfo>, engineFor: (SessionInfo) -> MochiEngine, onPick: (SessionInfo) -> Unit) {
    val t = tokens()
    Panel {
        others.forEachIndexed { i, s ->
            if (i > 0) RowDivider()
            val name = s.agent.ifBlank { Pills.byId(s.pillId)?.name.orEmpty() }
            val state = stringResource(stateLabel(s.state))
            Row(
                Modifier.fillMaxWidth().heightIn(min = 64.dp).clickable(role = Role.Button) { onPick(s) }
                    .padding(horizontal = Spacing.INSIDE.dp, vertical = 12.dp).semantics(mergeDescendants = true) {},
                horizontalArrangement = Arrangement.spacedBy(Spacing.GAP.dp), verticalAlignment = Alignment.CenterVertically,
            ) {
                MochiView(engineFor(s), Modifier.size(40.dp))
                Column(Modifier.weight(1f)) {
                    Text(name, style = TypeScale.BODY.style(t.text.c()).copy(fontWeight = FontWeight.SemiBold), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(HomeText.line(s) ?: state, style = TypeScale.SECONDARY.style(t.textDim.c()), maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                StateDot(stateColor(s.state))
            }
        }
    }
}

/** The last few things you allowed or denied, in plain words, with "See all" to the full list. */
@Composable
fun RecentPanel(decisions: List<Decision>, onAll: () -> Unit) {
    if (decisions.isEmpty()) return
    val t = tokens()
    val zone = androidx.compose.runtime.remember { ZoneId.systemDefault() }
    val timeFormat = androidx.compose.runtime.remember { DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT) }
    val dateFormat = androidx.compose.runtime.remember { DateTimeFormatter.ofLocalizedDate(FormatStyle.SHORT) }
    val now = System.currentTimeMillis()
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            SectionHeading(stringResource(R.string.recent_title), Modifier.weight(1f))
            Text(
                stringResource(R.string.recent_all),
                Modifier.heightIn(min = Spacing.MIN_TOUCH.dp).clickable(role = Role.Button, onClick = onAll).padding(horizontal = 4.dp, vertical = 12.dp),
                style = TypeScale.LABEL.style(t.textDim.c()),
            )
        }
        Panel {
            decisions.take(2).forEachIndexed { i, d ->
                if (i > 0) RowDivider()
                val (day, date) = HistoryDays.classify(d.atMs, now, zone)
                val whenText = when (day) {
                    HistoryDays.Day.TODAY -> timeFormat.format(Instant.ofEpochMilli(d.atMs).atZone(zone).toLocalTime())
                    HistoryDays.Day.YESTERDAY -> stringResource(R.string.history_yesterday)
                    HistoryDays.Day.OTHER -> dateFormat.format(date)
                }
                Row(
                    Modifier.fillMaxWidth().heightIn(min = 56.dp).clickable(role = Role.Button, onClick = onAll).padding(horizontal = Spacing.INSIDE.dp, vertical = 12.dp),
                    horizontalArrangement = Arrangement.spacedBy(Spacing.GAP.dp), verticalAlignment = Alignment.CenterVertically,
                ) {
                    StateDot(if (d.allowed) StatusColors.online else t.danger.c())
                    Text(HomeText.recent(d.allowed, d.tool), Modifier.weight(1f), style = TypeScale.BODY.style(t.text.c()), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(whenText, style = TypeScale.SECONDARY.style(t.textDim.c()), maxLines = 1)
                }
            }
        }
    }
}
