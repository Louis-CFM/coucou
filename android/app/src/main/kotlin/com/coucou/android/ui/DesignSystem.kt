package com.coucou.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.coucou.android.core.MotionPolicy
import com.coucou.android.core.MotionState
import com.coucou.android.core.Radii
import com.coucou.android.core.Spacing
import com.coucou.android.core.Tokens
import com.coucou.android.core.TypeScale
import com.coucou.android.core.TypeStep

// The app's building blocks: panels, pill buttons, the hero panel, the tokens of the (dark) theme.

/** The tokens of the current theme; CoucouTheme provides them. */
val LocalTokens = staticCompositionLocalOf { Tokens.DARK }

@Composable
@ReadOnlyComposable
fun tokens(): Tokens = LocalTokens.current

internal fun Long.c() = Color(this)

/**
 * True when motion is reduced: Android's "Remove animations" (unless the user chose otherwise in Settings > Reduce motion), or the
 * Settings choice to always reduce it. Springs and slides become plain fades or jumps, and Mochi stops his idle animations.
 */
@Composable
fun reducedMotion(): Boolean {
    val resolver = androidx.compose.ui.platform.LocalContext.current.contentResolver
    return MotionPolicy.reduced(MotionState.choice, android.provider.Settings.Global.getFloat(resolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 1f))
}

/** A step of the type scale as a Compose style. */
fun TypeStep.style(color: Color = Color.Unspecified) =
    TextStyle(fontSize = sizeSp.sp, lineHeight = lineSp.sp, fontWeight = FontWeight(weight), color = color)

/**
 * The island panel: `panel` colour, a thin border, radius 20. With [wash], a soft glow of that colour
 * rises from the bottom edge (the PC's `.wash`). Depth comes from the crisp border and soft ambient wash.
 */
@Composable
fun Panel(modifier: Modifier = Modifier, wash: Color? = null, content: @Composable ColumnScope.() -> Unit) {
    val t = tokens()
    val shape = RoundedCornerShape(Radii.PANEL.dp)
    Column(
        modifier.fillMaxWidth().clip(shape).background(t.panel.c()).border(1.dp, t.line.c(), shape)
            .then(if (wash != null) Modifier.drawBehind { drawWash(wash, t.washAlpha.toFloat()) } else Modifier),
        content = content,
    )
}

/** The glow: [color] at [alpha] under the bottom edge, gone by about 70% of the way up. */
internal fun DrawScope.drawWash(color: Color, alpha: Float) {
    drawRect(
        Brush.radialGradient(
            0f to color.copy(alpha = alpha), 1f to Color.Transparent,
            center = Offset(size.width / 2f, size.height * 1.3f), radius = size.width * 0.85f,
        ),
    )
}

/** The hero panel at the top of Home: hanging from the screen's top edge with Apple-inspired curvature. */
@Composable
fun HeroPanel(modifier: Modifier = Modifier, wash: Color? = null, content: @Composable ColumnScope.() -> Unit) {
    val t = tokens()
    val shape = RoundedCornerShape(bottomStart = Radii.HERO_BOTTOM.dp, bottomEnd = Radii.HERO_BOTTOM.dp)
    Column(
        modifier.fillMaxWidth().clip(shape).background(t.hero.c())
            .border(1.dp, t.heroLine.c(), shape)
            .then(if (wash != null) Modifier.drawBehind { drawWash(wash, t.washAlpha.toFloat()) } else Modifier),
        content = content,
    )
}

enum class PillKind { PRIMARY, SECONDARY, DANGER }

/**
 * The PC's buttons: one white (dark theme) pill for the main action, grey pills for the rest, and a
 * grey pill with a red label for what is destructive. 48 dp high, whatever the font size.
 */
@Composable
fun PillButton(
    text: String, onClick: () -> Unit, modifier: Modifier = Modifier, kind: PillKind = PillKind.SECONDARY,
    enabled: Boolean = true, onDark: Boolean = false, icon: (@Composable () -> Unit)? = null,
) {
    val t = tokens()
    // [onDark]: on a hero surface (the hero panel, a sheet, the island): the tokens in force there, dark on the island whatever the theme.
    val bg = when {
        onDark -> if (kind == PillKind.PRIMARY) t.heroPrimary else t.heroButton
        kind == PillKind.PRIMARY -> t.primaryButton
        else -> t.secondaryButton
    }
    val fg = when {
        kind == PillKind.DANGER -> t.danger
        onDark -> if (kind == PillKind.PRIMARY) t.heroOnPrimary else t.heroText
        kind == PillKind.PRIMARY -> t.onPrimaryButton
        else -> t.text
    }
    Row(
        modifier.alpha(if (enabled) 1f else 0.4f).heightIn(min = Spacing.MIN_TOUCH.dp).clip(CircleShape).background(bg.c())
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick).padding(horizontal = 20.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        icon?.invoke()
        Text(text, style = TypeScale.BODY.style(fg.c()).copy(fontWeight = FontWeight.SemiBold), maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** A small read-only capsule label: project name, model badge, or status chip. */
@Composable
fun Chip(text: String, modifier: Modifier = Modifier, tint: Color? = null) {
    val t = tokens()
    val bg = tint?.copy(alpha = 0.15f) ?: t.panel2.c()
    val fg = tint ?: t.text.c()
    Row(
        modifier.heightIn(min = 28.dp).clip(CircleShape).background(bg).padding(horizontal = 12.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        Text(text, style = TypeScale.LABEL.style(fg).copy(fontWeight = FontWeight.Medium), maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** The small heading above a panel, in iOS grouped style. */
@Composable
fun SectionHeading(text: String, modifier: Modifier = Modifier) {
    Text(
        text.uppercase(), modifier.padding(start = 6.dp, top = 12.dp, bottom = 4.dp),
        style = TypeScale.LABEL.style(tokens().textDim.c()).copy(letterSpacing = 0.7.sp, fontWeight = FontWeight.SemiBold),
        maxLines = 1, overflow = TextOverflow.Ellipsis,
    )
}

/** An iOS grouped row inside a panel: title, optional hint under it, trailing accessory. Tappable when [onClick] is given. */
@Composable
fun ListRow(
    title: String, modifier: Modifier = Modifier, hint: String? = null, onClick: (() -> Unit)? = null,
    trailing: (@Composable RowScope.() -> Unit)? = null,
) {
    val t = tokens()
    Row(
        modifier.fillMaxWidth().heightIn(min = 56.dp)
            .then(if (onClick != null) Modifier.clickable(role = Role.Button, onClick = onClick) else Modifier)
            .padding(horizontal = Spacing.INSIDE.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(Spacing.GAP.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = TypeScale.BODY.style(t.text.c()).copy(fontWeight = FontWeight.SemiBold), maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (hint != null) Text(hint, style = TypeScale.SECONDARY.style(t.textDim.c()), maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        trailing?.invoke(this)
    }
}

/** The thin line between two rows of one panel. Optional [startIndent] for iOS grouped table style. */
@Composable
fun RowDivider(startIndent: Dp = 0.dp) {
    Box(
        Modifier.fillMaxWidth().padding(start = startIndent).height(0.8.dp).background(tokens().line.c()),
    )
}

/** The coloured status dot with subtle halo for Apple-grade clarity. */
@Composable
fun StateDot(color: Color, modifier: Modifier = Modifier) {
    Box(
        modifier.size(10.dp),
        contentAlignment = Alignment.Center,
    ) {
        Box(Modifier.size(10.dp).clip(CircleShape).background(color.copy(alpha = 0.22f)))
        Box(Modifier.size(6.dp).clip(CircleShape).background(color))
    }
}
