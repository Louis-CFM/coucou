package com.coucou.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.coucou.android.R
import com.coucou.android.core.RecapText
import com.coucou.android.core.Spacing
import com.coucou.android.core.TypeScale
import com.coucou.android.link.Recap

/**
 * Last week's analytics, presented as an Apple-inspired metrics summary.
 * Read-only statistics with structured rows, bold numbers, and full TalkBack sentence descriptions.
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
            stats.forEachIndexed { i, (label, value) ->
                if (i > 0) RowDivider(startIndent = 16.dp)
                Row(
                    Modifier
                        .fillMaxWidth()
                        .padding(horizontal = Spacing.INSIDE.dp, vertical = 11.dp)
                        .semantics(mergeDescendants = true) { contentDescription = "$label: $value" },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        label,
                        Modifier.weight(1f),
                        style = TypeScale.BODY.style(t.textDim.c()),
                    )
                    Text(
                        value,
                        style = TypeScale.BODY.style(t.text.c()).copy(fontWeight = FontWeight.SemiBold),
                    )
                }
            }
        }
    }
}
