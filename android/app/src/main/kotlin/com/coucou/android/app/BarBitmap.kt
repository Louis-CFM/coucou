package com.coucou.android.app

import android.graphics.Bitmap
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Canvas
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.drawscope.CanvasDrawScope
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import com.coucou.android.core.UsageRing
import kotlin.math.max

/**
 * The thin bar of a plan-usage row on Mochi Big, drawn once into a bitmap like [RingBitmap] draws the Usage Ring's ring: a faint
 * track and a rounded fill in the colour of the usage (teal, yellow from 75%, red from 90%: [com.coucou.android.core.PlanUsageLook]). A few are kept so a push that changes
 * nothing about a bar draws nothing. No timer, no frame loop.
 */
object BarBitmap {
    private const val KEEP = 8
    private const val TRACK = 0x40808080

    private data class Key(val pct: Int, val tone: Int, val width: Int, val height: Int)

    private val cache = object : LinkedHashMap<Key, Bitmap>(8, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Key, Bitmap>) = size > KEEP
    }

    /** The bar for [row], [widthPx] by [heightPx]. */
    @Synchronized
    fun of(row: UsageRing, widthPx: Int, heightPx: Int): Bitmap {
        val key = Key(row.shown, row.tone.argb, widthPx, heightPx)
        return cache.getOrPut(key) { draw(row, widthPx, heightPx) }
    }

    private fun draw(row: UsageRing, widthPx: Int, heightPx: Int): Bitmap {
        val image = ImageBitmap(widthPx, heightPx)
        val round = CornerRadius(heightPx / 2f, heightPx / 2f)
        CanvasDrawScope().draw(Density(1f), LayoutDirection.Ltr, Canvas(image), Size(widthPx.toFloat(), heightPx.toFloat())) {
            drawRoundRect(Color(TRACK), Offset.Zero, Size(widthPx.toFloat(), heightPx.toFloat()), round)
            if (row.fraction > 0f) {
                // Never narrower than its own height, so a small value still shows a round dot.
                val fill = max(heightPx.toFloat(), widthPx * row.fraction)
                drawRoundRect(Color(row.tone.argb), Offset.Zero, Size(fill, heightPx.toFloat()), round)
            }
        }
        return image.asAndroidBitmap()
    }
}
