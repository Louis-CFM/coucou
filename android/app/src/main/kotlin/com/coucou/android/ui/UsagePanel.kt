package com.coucou.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.coucou.android.R
import com.coucou.android.core.PlanText
import com.coucou.android.core.Spacing
import com.coucou.android.core.TypeScale
import com.coucou.android.link.PlanUsage
import com.coucou.android.link.PlanWindow
import com.coucou.android.link.UsageSnapshot

/**
 * How much of the Claude and Codex plans is used and when they reset, presented in Apple Screen Time style.
 * Each bar clearly displays its percentage in words for TalkBack and visual accessibility.
 */
@Composable
fun UsagePanel(usage: UsageSnapshot?, nowMs: Long = System.currentTimeMillis()) {
    if (usage == null || (usage.claude == null && usage.codex == null)) return
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        SectionHeading(stringResource(R.string.usage_title))
        Panel {
            var first = true
            usage.claude?.let {
                PlanBlock(stringResource(R.string.usage_claude), it, nowMs)
                first = false
            }
            usage.codex?.let {
                if (!first) RowDivider(startIndent = 16.dp)
                PlanBlock(stringResource(R.string.usage_codex), it, nowMs)
            }
        }
    }
}

@Composable
private fun PlanBlock(name: String, plan: PlanUsage, nowMs: Long) {
    val t = tokens()
    Column(
        Modifier
            .fillMaxWidth()
            .padding(Spacing.INSIDE.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                name,
                Modifier.weight(1f),
                style = TypeScale.HEADLINE.style(t.text.c()).copy(fontWeight = FontWeight.SemiBold),
            )
            plan.plan?.let {
                Box(
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(t.panel2.c())
                        .padding(horizontal = 8.dp, vertical = 3.dp),
                ) {
                    Text(
                        it,
                        style = TypeScale.LABEL.style(t.textDim.c()).copy(fontSize = 11.sp),
                        maxLines = 1,
                    )
                }
            }
        }
        plan.fiveHour?.let { WindowBar(name, stringResource(R.string.usage_five_hours), it, nowMs, weekly = false) }
        plan.sevenDay?.let { WindowBar(name, stringResource(R.string.usage_week), it, nowMs, weekly = true) }
        plan.resetCredits?.takeIf { it > 0 }?.let {
            Text(stringResource(R.string.usage_credits, it), style = TypeScale.SECONDARY.style(t.textDim.c()))
        }
    }
}

@Composable
private fun WindowBar(plan: String, label: String, w: PlanWindow, nowMs: Long, weekly: Boolean) {
    val t = tokens()
    val pct = PlanText.effectivePct(w, nowMs)
    val color = when (PlanText.level(pct)) {
        PlanText.Level.LOW -> StatusColors.online
        PlanText.Level.MEDIUM -> StatusColors.busy
        PlanText.Level.HIGH -> t.danger.c()
    }
    val reset = if (weekly && w.resetsAtMs > nowMs) stringResource(R.string.usage_resets_week, PlanText.weekday(w))
    else when (val r = PlanText.resetsIn(w, nowMs)) {
        PlanText.Reset.Now -> stringResource(R.string.usage_resets_now)
        is PlanText.Reset.InHoursMinutes -> stringResource(R.string.usage_resets_hm, r.h, r.m)
        is PlanText.Reset.InMinutes -> stringResource(R.string.usage_resets_m, r.m)
    }
    val spoken = stringResource(R.string.usage_desc, plan, label, pct)

    Column(
        Modifier.semantics(mergeDescendants = true) { contentDescription = "$spoken. $reset" },
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(Modifier.clearAndSetSemantics { }, verticalAlignment = Alignment.CenterVertically) {
            Text(label, Modifier.weight(1f), style = TypeScale.BODY.style(t.text.c()).copy(fontWeight = FontWeight.Medium))
            Text(stringResource(R.string.usage_pct, pct), style = TypeScale.BODY.style(t.text.c()).copy(fontWeight = FontWeight.SemiBold), maxLines = 1)
        }
        // Apple Screen Time styled rounded track and fill
        Box(
            Modifier
                .fillMaxWidth()
                .height(7.dp)
                .clip(CircleShape)
                .background(t.secondaryButton.c())
                .clearAndSetSemantics { },
        ) {
            Box(
                Modifier
                    .fillMaxWidth(pct / 100f)
                    .height(7.dp)
                    .clip(CircleShape)
                    .background(color),
            )
        }
        Text(reset, Modifier.clearAndSetSemantics { }, style = TypeScale.SECONDARY.style(t.textDim.c()), maxLines = 2)
    }
}
