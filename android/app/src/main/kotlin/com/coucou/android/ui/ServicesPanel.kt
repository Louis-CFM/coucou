package com.coucou.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.coucou.android.R
import com.coucou.android.core.Spacing
import com.coucou.android.core.TypeScale
import com.coucou.android.link.ServiceCard

/**
 * The service cards the user allowed on the computer, read-only: the same headline and short lines as the pills
 * there. Styled as Apple iOS widget cards with clear visual hierarchy.
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
        Column(
            Modifier
                .fillMaxWidth()
                .padding(Spacing.INSIDE.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    c.title,
                    Modifier.weight(1f),
                    style = TypeScale.SECONDARY.style(t.textDim.c()).copy(fontWeight = FontWeight.Medium),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                c.reason?.let {
                    Box(
                        modifier = Modifier
                            .clip(CircleShape)
                            .background(t.panel2.c())
                            .padding(horizontal = 8.dp, vertical = 2.dp),
                    ) {
                        Text(
                            it,
                            style = TypeScale.LABEL.style(t.textDim.c()).copy(fontSize = 11.sp),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
            Text(
                c.headline,
                style = TypeScale.TITLE.style(t.text.c()).copy(letterSpacing = (-0.3).sp, fontWeight = FontWeight.Bold),
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            if (c.items.isNotEmpty()) {
                Column(
                    modifier = Modifier.padding(top = 2.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    for (line in c.items) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(Spacing.GAP.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                line.label,
                                Modifier.weight(1f),
                                style = TypeScale.BODY.style(t.text.c()),
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis,
                            )
                            if (line.detail.isNotEmpty()) {
                                Text(
                                    line.detail,
                                    style = TypeScale.SECONDARY.style(t.textDim.c()).copy(fontWeight = FontWeight.Medium),
                                    maxLines = 1,
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}
