package com.coucou.android.ui

import androidx.compose.animation.core.snap
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.coucou.android.core.Spacing
import kotlin.math.roundToInt

private val TRACK_W = 52.dp
private val TRACK_H = 30.dp
private val KNOB = 22.dp

/**
 * The on/off switch: a 52 x 30 pill with a white knob that springs across, green when on. The hit area
 * is 48 dp high. It is a real toggle for TalkBack (role Switch, with its state), unlike a plain box.
 */
@Composable
fun CoucouSwitch(checked: Boolean, onChange: (Boolean) -> Unit, modifier: Modifier = Modifier, label: String? = null, enabled: Boolean = true) {
    val t = tokens()
    val reduced = reducedMotion()
    val knobX by animateDpAsState(if (checked) 22.dp else 0.dp, if (reduced) snap() else spring(dampingRatio = 0.72f, stiffness = 400f), label = "knob")
    Box(
        modifier.alpha(if (enabled) 1f else 0.4f).sizeIn(minWidth = TRACK_W, minHeight = Spacing.MIN_TOUCH.dp)
            .toggleable(value = checked, enabled = enabled, role = Role.Switch, onValueChange = onChange)
            .semantics { if (label != null) contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier.size(TRACK_W, TRACK_H).clip(CircleShape)
                .background(if (checked) t.online.c() else t.panel2.c())
                .border(1.dp, if (checked) Color.Transparent else t.line.c(), CircleShape),
        ) {
            Box(Modifier.offset(x = 3.dp + knobX, y = 3.dp).size(KNOB).clip(CircleShape).background(Color.White))
        }
    }
}

/**
 * The slider: a 4 dp rail, the part before the knob in the text colour, and a 22 dp white round knob.
 * Tap or drag; TalkBack can step it through its progress action. 48 dp high so it is easy to hit.
 */
@Composable
fun CoucouSlider(
    value: Float, onChange: (Float) -> Unit, modifier: Modifier = Modifier,
    valueRange: ClosedFloatingPointRange<Float> = 0f..1f, enabled: Boolean = true, label: String = "",
) {
    val t = tokens()
    val latest by rememberUpdatedState(onChange)
    val density = LocalDensity.current
    BoxWithConstraints(modifier.alpha(if (enabled) 1f else 0.4f).fillMaxWidth().height(Spacing.MIN_TOUCH.dp)) {
        val widthPx = constraints.maxWidth.toFloat()
        val knobPx = with(density) { KNOB.toPx() }
        val usable = (widthPx - knobPx).coerceAtLeast(1f)
        val span = valueRange.endInclusive - valueRange.start
        val fraction = if (span <= 0f) 0f else ((value - valueRange.start) / span).coerceIn(0f, 1f)
        fun fromX(x: Float): Float = valueRange.start + ((x - knobPx / 2f) / usable).coerceIn(0f, 1f) * span
        Box(
            Modifier.fillMaxSize()
                .pointerInput(enabled, valueRange) { if (enabled) detectTapGestures { latest(fromX(it.x)) } }
                .pointerInput(enabled, valueRange) { if (enabled) detectHorizontalDragGestures { change, _ -> latest(fromX(change.position.x)) } }
                .semantics {
                    contentDescription = label
                    progressBarRangeInfo = ProgressBarRangeInfo(value.coerceIn(valueRange), valueRange)
                    setProgress { target -> latest(target.coerceIn(valueRange)); true }
                },
        ) {
            Box(Modifier.align(Alignment.CenterStart).fillMaxWidth().height(4.dp).clip(CircleShape).background(t.panel2.c()))
            Box(
                Modifier.align(Alignment.CenterStart).height(4.dp).clip(CircleShape).background(t.text.c())
                    .width(with(density) { (knobPx / 2f + fraction * usable).toDp() }),
            )
            Box(
                Modifier.align(Alignment.CenterStart).offset { IntOffset((fraction * usable).roundToInt(), 0) }
                    .size(KNOB).clip(CircleShape).background(Color.White).border(1.dp, Color.Black.copy(alpha = 0.25f), CircleShape),
            )
        }
    }
}
