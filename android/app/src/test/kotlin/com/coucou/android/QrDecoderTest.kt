package com.coucou.android

import com.coucou.android.scan.QrDecoder
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The decoder against real QR codes made by zxing's own encoder, drawn as a camera would give them (brightness bytes). */
class QrDecoderTest {
    private val fp = "ab".repeat(32)
    private val text = "coucou://pair?v=1&host=192.168.1.20&port=47821&fp=$fp&token=T0ken_with-16plus_chars&name=My%20PC"

    private class Frame(val luma: ByteArray, val stride: Int, val w: Int, val h: Int)

    /** The code drawn [scale] pixels per module on a light background with a quiet zone, padded to [stride]. */
    private fun frame(content: String, scale: Int = 6, margin: Int = 4, inverted: Boolean = false, extraStride: Int = 0, rotate: Boolean = false): Frame {
        val m = QRCodeWriter().encode(content, BarcodeFormat.QR_CODE, 0, 0, mapOf(EncodeHintType.MARGIN to 0, EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M))
        val n = m.width
        var side = (n + 2 * margin) * scale
        val img = Array(side) { IntArray(side) { 255 } }
        for (y in 0 until n) for (x in 0 until n) if (m.get(x, y)) {
            for (dy in 0 until scale) for (dx in 0 until scale) img[(y + margin) * scale + dy][(x + margin) * scale + dx] = 0
        }
        var rows = img
        if (rotate) rows = Array(side) { y -> IntArray(side) { x -> img[side - 1 - x][y] } }
        val stride = side + extraStride
        val out = ByteArray(stride * side)
        for (y in 0 until side) for (x in 0 until side) {
            val v = if (inverted) 255 - rows[y][x] else rows[y][x]
            out[y * stride + x] = v.toByte()
        }
        return Frame(out, stride, side, side)
    }

    private fun QrDecoder.read(f: Frame) = decode(f.luma, f.stride, f.w, f.h)

    @Test fun readsAPairingCode() {
        assertEquals(text, QrDecoder().read(frame(text)))
    }

    @Test fun readsASmallCodeToo() {
        assertEquals(text, QrDecoder().read(frame(text, scale = 3)))
    }

    @Test fun readsACodeInAFrameWhoseRowsAreWiderThanTheImage() {
        // Camera frames pad each row (rowStride > width): that must not skew the picture.
        assertEquals(text, QrDecoder().read(frame(text, extraStride = 37)))
    }

    @Test fun readsACodeTurnedOnItsSide() {
        assertEquals(text, QrDecoder().read(frame(text, rotate = true)))
    }

    @Test fun readsALightCodeOnADarkBackground() {
        assertEquals(text, QrDecoder().read(frame(text, inverted = true)))
    }

    @Test fun readsOtherTextToo_decidingWhatItMeansIsNotItsJob() {
        assertEquals("https://example.com/shop?id=1", QrDecoder().read(frame("https://example.com/shop?id=1")))
    }

    @Test fun anEmptyOrNoisyFrameHasNoCode() {
        val d = QrDecoder()
        assertNull(d.decode(ByteArray(640 * 480) { 128.toByte() }, 640, 640, 480))
        val rnd = java.util.Random(1)
        assertNull(d.decode(ByteArray(300 * 300).also { rnd.nextBytes(it) }, 300, 300, 300))
    }

    @Test fun badDimensionsNeverThrow() {
        val d = QrDecoder()
        assertNull(d.decode(ByteArray(0), 0, 0, 0))
        assertNull(d.decode(ByteArray(10), 5, 10, 10))
        assertNull(d.decode(ByteArray(100), 10, 20, 10)) // stride smaller than width
        assertNull(d.decode(ByteArray(50), 10, 10, 10))  // buffer too short
    }

    @Test fun oneDecoderServesManyFramesInARow() {
        val d = QrDecoder()
        assertNull(d.decode(ByteArray(200 * 200) { 255.toByte() }, 200, 200, 200))
        assertEquals(text, d.read(frame(text)))
        assertNull(d.decode(ByteArray(200 * 200) { 0 }, 200, 200, 200))
        assertEquals("second", d.read(frame("second")))
    }
}
