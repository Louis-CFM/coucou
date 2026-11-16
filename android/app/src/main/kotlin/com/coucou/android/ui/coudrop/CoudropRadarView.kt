package com.coucou.android.ui.coudrop

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.coucou.android.core.IconKind
import com.coucou.android.link.LinkState
import com.coucou.android.ui.CoucouIcon

/**
 * Concentric animated radar wave pulse for Coudrop peer-to-peer discovery.
 */
@Composable
fun CoudropRadarView(
    linkState: LinkState,
    modifier: Modifier = Modifier,
    size: Dp = 180.dp,
) {
    val isConnected = linkState == LinkState.CONNECTED
    val baseColor = if (isConnected) Color(0xFF30D158) else Color(0xFF8E8E93)

    val transition = rememberInfiniteTransition(label = "coudrop_radar")
    val pulse1 by transition.animateFloat(
        initialValue = 0.2f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 2400, easing = LinearEasing),
            repeatMode = RepeatMode.Restart,
        ),
        label = "pulse1",
    )
    val pulse2 by transition.animateFloat(
        initialValue = 0.2f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 2400, delayMillis = 800, easing = LinearEasing),
            repeatMode = RepeatMode.Restart,
        ),
        label = "pulse2",
    )
    val pulse3 by transition.animateFloat(
        initialValue = 0.2f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 2400, delayMillis = 1600, easing = LinearEasing),
            repeatMode = RepeatMode.Restart,
        ),
        label = "pulse3",
    )

    Box(modifier = modifier.size(size), contentAlignment = Alignment.Center) {
        Canvas(modifier = Modifier.size(size)) {
            val maxRadius = size.toPx() / 2f

            if (isConnected) {
                listOf(pulse1, pulse2, pulse3).forEach { p ->
                    val r = maxRadius * p
                    val alpha = (1f - p).coerceIn(0f, 1f) * 0.45f
                    drawCircle(
                        color = baseColor.copy(alpha = alpha),
                        radius = r,
                        style = Stroke(width = 2.dp.toPx()),
                    )
                }
            } else {
                drawCircle(
                    color = baseColor.copy(alpha = 0.15f),
                    radius = maxRadius * 0.6f,
                    style = Stroke(width = 1.5.dp.toPx()),
                )
                drawCircle(
                    color = baseColor.copy(alpha = 0.08f),
                    radius = maxRadius * 0.85f,
                    style = Stroke(width = 1.5.dp.toPx()),
                )
            }
        }

        // Center hub button
        Box(
            modifier = Modifier
                .size(64.dp)
                .clip(CircleShape)
                .background(if (isConnected) Color(0xFF0A84FF).copy(alpha = 0.16f) else Color(0xFF2C2C2E))
                .border(
                    width = 1.5.dp,
                    color = if (isConnected) Color(0xFF0A84FF).copy(alpha = 0.6f) else Color(0xFF3A3A3C),
                    shape = CircleShape,
                ),
            contentAlignment = Alignment.Center,
        ) {
            CoucouIcon(
                kind = IconKind.SEND,
                tint = if (isConnected) Color(0xFF0A84FF) else Color(0xFF8E8E93),
                size = 28.dp,
            )
        }
    }
}
