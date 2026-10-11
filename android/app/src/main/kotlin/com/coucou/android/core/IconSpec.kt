package com.coucou.android.core

/**
 * The app's icons as geometry on a 24 x 24 grid, stroked 1.9 wide with round ends and joins (the same
 * drawing style as the PC's `views/icons.ts`). No icon library: ui/DesignIcons.kt draws these.
 * Pure data, so a test can check every point is on the grid and every icon has a drawing.
 */
sealed interface IconShape {
    /** Straight segments through [points] (x1, y1, x2, y2, ...). */
    data class Poly(val points: List<Double>) : IconShape
    data class Circle(val cx: Double, val cy: Double, val r: Double) : IconShape
    data class RoundRect(val x: Double, val y: Double, val w: Double, val h: Double, val r: Double) : IconShape
    /** An arc of the circle at ([cx], [cy]): [start] and [sweep] in degrees, clockwise from three o'clock. */
    data class Arc(val cx: Double, val cy: Double, val r: Double, val start: Double, val sweep: Double) : IconShape
}

enum class IconKind { HOME, CHAT, SLIDERS, BACK, SEND, LOCK, SCAN, CHEVRON, CHECK, CLOSE }

object IconSpec {
    const val GRID = 24.0
    const val STROKE = 1.9

    private fun poly(vararg p: Double) = IconShape.Poly(p.toList())

    fun shapes(kind: IconKind): List<IconShape> = when (kind) {
        IconKind.HOME -> listOf(poly(4.0, 11.5, 12.0, 5.0, 20.0, 11.5), poly(6.0, 10.5, 6.0, 19.0, 18.0, 19.0, 18.0, 10.5))
        IconKind.CHAT -> listOf(IconShape.RoundRect(3.5, 5.5, 17.0, 12.0, 2.0), poly(11.0, 17.5, 7.0, 20.5, 7.0, 17.5))
        // Three horizontal rails with two knobs: "adjust", never a sun or a gear.
        IconKind.SLIDERS -> listOf(
            poly(4.0, 7.0, 13.0, 7.0), poly(17.0, 7.0, 20.0, 7.0), poly(4.0, 17.0, 7.0, 17.0), poly(11.0, 17.0, 20.0, 17.0),
            IconShape.Circle(15.0, 7.0, 2.0), IconShape.Circle(9.0, 17.0, 2.0),
        )
        IconKind.BACK -> listOf(poly(14.5, 6.0, 8.5, 12.0, 14.5, 18.0))
        IconKind.SEND -> listOf(poly(12.0, 19.0, 12.0, 6.0), poly(6.5, 11.5, 12.0, 6.0, 17.5, 11.5))
        IconKind.LOCK -> listOf(
            IconShape.RoundRect(5.5, 10.5, 13.0, 9.0, 2.5), poly(8.5, 10.5, 8.5, 8.0), poly(15.5, 10.5, 15.5, 8.0),
            IconShape.Arc(12.0, 8.0, 3.5, 180.0, 180.0),
        )
        IconKind.SCAN -> listOf(
            poly(4.0, 8.0, 4.0, 6.0, 6.0, 4.0, 8.0, 4.0), poly(16.0, 4.0, 18.0, 4.0, 20.0, 6.0, 20.0, 8.0),
            poly(20.0, 16.0, 20.0, 18.0, 18.0, 20.0, 16.0, 20.0), poly(8.0, 20.0, 6.0, 20.0, 4.0, 18.0, 4.0, 16.0),
            poly(8.0, 12.0, 16.0, 12.0),
        )
        IconKind.CHEVRON -> listOf(poly(9.5, 6.0, 15.5, 12.0, 9.5, 18.0))
        IconKind.CHECK -> listOf(poly(5.5, 12.5, 9.7, 16.7, 18.5, 7.5))
        IconKind.CLOSE -> listOf(poly(7.0, 7.0, 17.0, 17.0), poly(17.0, 7.0, 7.0, 17.0))
    }

    /** Every x and y the icon uses, including the extent of circles, rectangles and arcs. */
    fun extent(kind: IconKind): List<Double> = shapes(kind).flatMap {
        when (it) {
            is IconShape.Poly -> it.points
            is IconShape.Circle -> listOf(it.cx - it.r, it.cx + it.r, it.cy - it.r, it.cy + it.r)
            is IconShape.RoundRect -> listOf(it.x, it.x + it.w, it.y, it.y + it.h)
            is IconShape.Arc -> listOf(it.cx - it.r, it.cx + it.r, it.cy - it.r, it.cy + it.r)
        }
    }
}
