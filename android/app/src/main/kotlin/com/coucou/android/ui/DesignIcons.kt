package com.coucou.android.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.coucou.android.core.IconKind
import com.coucou.android.core.IconShape
import com.coucou.android.core.IconSpec

/** Draws an icon from core/IconSpec.kt: stroked, round ends and joins, scaled from the 24 grid to [size]. No icon library. */
@Composable
fun CoucouIcon(kind: IconKind, modifier: Modifier = Modifier, tint: Color = tokens().text.c(), size: Dp = 24.dp) {
    Canvas(modifier.size(size)) { drawIcon(kind, tint) }
}

private fun DrawScope.drawIcon(kind: IconKind, tint: Color) {
    val k = (size.minDimension / IconSpec.GRID.toFloat())
    val stroke = Stroke(width = IconSpec.STROKE.toFloat() * k, cap = StrokeCap.Round, join = StrokeJoin.Round)
    fun p(v: Double) = v.toFloat() * k
    for (s in IconSpec.shapes(kind)) when (s) {
        is IconShape.Poly -> {
            val path = Path()
            for (i in 0 until s.points.size / 2) {
                val x = p(s.points[2 * i])
                val y = p(s.points[2 * i + 1])
                if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
            }
            drawPath(path, tint, style = stroke)
        }
        is IconShape.Circle -> drawCircle(tint, radius = p(s.r), center = Offset(p(s.cx), p(s.cy)), style = stroke)
        is IconShape.RoundRect -> drawRoundRect(
            tint, topLeft = Offset(p(s.x), p(s.y)), size = Size(p(s.w), p(s.h)), cornerRadius = CornerRadius(p(s.r)), style = stroke,
        )
        is IconShape.Arc -> drawArc(
            tint, startAngle = s.start.toFloat(), sweepAngle = s.sweep.toFloat(), useCenter = false,
            topLeft = Offset(p(s.cx - s.r), p(s.cy - s.r)), size = Size(p(2 * s.r), p(2 * s.r)), style = stroke,
        )
    }
}
