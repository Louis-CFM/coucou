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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.coucou.android.R
import com.coucou.android.core.Spacing
import com.coucou.android.core.TypeScale
import com.coucou.android.link.ServiceCard

/**
 * The service cards the user allowed on the computer, read-only: the same headline and short lines as the pills
 * there. Nothing here can be tapped to change anything, and no link or address is ever in a card.
 */
@Composable
fun ServicesPanel(cards: List<ServiceCard>) {
    if (cards.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        SectionHeading(stringResource(R.string.services_title))
        for (c in cards) ServiceCardView(c)
    }
}

@Composable
private fun ServiceCardView(c: ServiceCard) {
    val t = tokens()
    Panel {
        Column(Modifier.fillMaxWidth().padding(Spacing.INSIDE.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(c.title, Modifier.weight(1f), style = TypeScale.SECONDARY.style(t.textDim.c()), maxLines = 1, overflow = TextOverflow.Ellipsis)
                c.reason?.let { Text(it, style = TypeScale.LABEL.style(t.textDim.c()), maxLines = 1, overflow = TextOverflow.Ellipsis) }
            }
            Text(c.headline, style = TypeScale.TITLE.style(t.text.c()), maxLines = 2, overflow = TextOverflow.Ellipsis)
            for (line in c.items) {
                Row(horizontalArrangement = Arrangement.spacedBy(Spacing.GAP.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(line.label, Modifier.weight(1f), style = TypeScale.BODY.style(t.text.c()), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    if (line.detail.isNotEmpty()) Text(line.detail, style = TypeScale.SECONDARY.style(t.textDim.c()), maxLines = 1)
                }
            }
        }
    }
}
