package com.coucou.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.coucou.android.R
import com.coucou.android.core.RecapText
import com.coucou.android.core.Spacing
import com.coucou.android.core.TypeScale
import com.coucou.android.link.Recap

/**
 * Last week's numbers, as the computer counted them (its switch is on): time with agents, sessions, files, lines, commands, permissions and
 * the agent used most. Counts only; read-only; nothing goes back. TalkBack reads the card as one sentence per stat.
 */
@Composable
fun RecapPanel(recap: Recap?) {
    if (recap == null) return
    val t = tokens()
    val stats = RecapText.stats(recap)
    val week = RecapText.weekLabel(recap.week)
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        SectionHeading(stringResource(R.string.recap_title) + (week?.let { " · $it" } ?: ""))
        Panel {
            Column(Modifier.fillMaxWidth().padding(Spacing.INSIDE.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                for ((label, value) in stats) {
                    Row(Modifier.fillMaxWidth().semantics(mergeDescendants = true) { contentDescription = "$label: $value" }) {
                        Text(label, Modifier.weight(1f), style = TypeScale.BODY.style(t.textDim.c()))
                        Text(value, style = TypeScale.BODY.style(t.text.c()))
                    }
                }
            }
        }
    }
}
