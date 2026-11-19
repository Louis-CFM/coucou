package com.coucou.android.ui

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.coucou.android.R
import com.coucou.android.core.BarFit
import com.coucou.android.core.IconKind
import com.coucou.android.core.Spacing
import com.coucou.android.core.SpokenLabels
import com.coucou.android.core.Tab
import com.coucou.android.core.TypeScale
import com.coucou.android.mochi.BotState
import com.coucou.android.mochi.MochiConst

private fun Tab.icon() = when (this) {
    Tab.HOME -> IconKind.HOME
    Tab.CHAT -> IconKind.CHAT
    Tab.SETTINGS -> IconKind.SLIDERS
}

private fun Tab.label() = when (this) {
    Tab.HOME -> R.string.tab_home
    Tab.CHAT -> R.string.tab_chat
    Tab.SETTINGS -> R.string.tab_settings
}

/**
 * The floating bar: a refined Apple-inspired pill with Home, Chat, and Settings tabs.
 * Smooth animated selection pill, crisp icon/label alignment, and comfortable 48dp touch targets.
 * Labels are always shown; the active tab has a subtle elevated pill behind it.
 * [alert] puts the approval amber dot on Home when a request is waiting.
 */
@Composable
fun BottomBar(tabs: List<Tab>, selected: Tab?, onSelect: (Tab) -> Unit, alert: Boolean, modifier: Modifier = Modifier) {
    val t = tokens()
    val homeAlert = stringResource(R.string.tab_home_alert)
    val reduced = reducedMotion()

    Row(
        // At least 64 dp, taller when the font is large, so labels are never cut.
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 24.dp)
            .height(IntrinsicSize.Min).heightIn(min = 64.dp)
            .shadow(elevation = if (t.isDark) 12.dp else 8.dp, shape = CircleShape, spotColor = Color.Black.copy(alpha = 0.25f))
            .clip(CircleShape)
            .background(t.panel.c())
            .border(1.dp, t.line.c(), CircleShape)
            .padding(5.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        for (tab in tabs) {
            val on = tab == selected
            val label = stringResource(tab.label())

            val tabBg by animateColorAsState(
                targetValue = if (on) t.panel2.c() else Color.Transparent,
                animationSpec = if (reduced) tween(0) else spring(stiffness = Spring.StiffnessMediumLow),
                label = "tab_bg",
            )
            val iconTint by animateColorAsState(
                targetValue = if (on) t.text.c() else t.textDim.c(),
                animationSpec = if (reduced) tween(0) else tween(180),
                label = "tab_icon",
            )
            val labelTint by animateColorAsState(
                targetValue = if (on) t.text.c() else t.textDim.c(),
                animationSpec = if (reduced) tween(0) else tween(180),
                label = "tab_label",
            )

            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxHeight()
                    .heightIn(min = Spacing.MIN_TOUCH.dp)
                    .clip(CircleShape)
                    .background(tabBg)
                    .selectable(selected = on, role = Role.Tab, onClick = { onSelect(tab) })
                    .semantics { contentDescription = SpokenLabels.tab(label, alert && tab == Tab.HOME, homeAlert) },
                contentAlignment = Alignment.Center,
            ) {
                Column(
                    modifier = Modifier.padding(horizontal = BarFit.ITEM_SIDE_PADDING_DP.dp, vertical = 6.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    CoucouIcon(tab.icon(), tint = iconTint, size = 22.dp)
                    Text(
                        label,
                        style = TypeScale.LABEL.style(labelTint).copy(
                            fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal,
                            letterSpacing = 0.2.sp,
                        ),
                        maxLines = 1,
                        softWrap = false,
                    )
                }

                if (alert && tab == Tab.HOME) {
                    val amber = MochiConst.STATES[BotState.APPROVAL]?.color?.let(::rgbColor) ?: Color(0xFFF5A524)
                    Box(
                        Modifier
                            .align(Alignment.TopCenter)
                            .padding(start = 22.dp, top = 4.dp)
                            .size(9.dp)
                            .clip(CircleShape)
                            .background(amber)
                            .border(1.5.dp, t.panel.c(), CircleShape),
                    )
                }
            }
        }
    }
}
