package com.coucou.android.app

import android.graphics.Bitmap
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Canvas
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.drawscope.CanvasDrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import com.coucou.android.core.UsageRing

/**
 * The ring of the Usage Ring widget, drawn once into a bitmap: a faint track and an arc in the tone of the usage, starting at
 * the top. A few are kept so a push that changes nothing about the ring draws nothing. No timer, no frame loop.
 */
object RingBitmap {
    private const val KEEP = 6
    private const val TRACK = 0x40808080
    private const val STROKE = 0.12f

    private data class Key(val pct: Int, val tone: Int, val size: Int)

    private val cache = object : LinkedHashMap<Key, Bitmap>(8, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Key, Bitmap>) = size > KEEP
    }

    /** The ring for [ring], [sizePx] pixels square. */
    @Synchronized
    fun of(ring: UsageRing, sizePx: Int): Bitmap {
        val key = Key(ring.shown, ring.tone.argb, sizePx)
        return cache.getOrPut(key) { draw(ring, sizePx) }
    }

    private fun draw(ring: UsageRing, sizePx: Int): Bitmap {
        val image = ImageBitmap(sizePx, sizePx)
        val stroke = sizePx * STROKE
        val box = Size(sizePx - stroke, sizePx - stroke)
        val corner = Offset(stroke / 2, stroke / 2)
        CanvasDrawScope().draw(Density(1f), LayoutDirection.Ltr, Canvas(image), Size(sizePx.toFloat(), sizePx.toFloat())) {
            drawArc(Color(TRACK), 0f, 360f, false, corner, box, style = Stroke(stroke))
            if (ring.fraction > 0f) {
                drawArc(Color(ring.tone.argb), -90f, 360f * ring.fraction, false, corner, box, style = Stroke(stroke, cap = StrokeCap.Round))
            }
        }
        return image.asAndroidBitmap()
    }
}
