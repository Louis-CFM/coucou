package com.coucou.android.mochi.outfit

import com.coucou.android.ReferenceFiles
import java.io.File
import java.util.concurrent.TimeUnit
import kotlin.math.abs
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/** A [Gfx] that writes down what it was asked to draw, in the same JSON shape as android/tools/outfit-trace.mjs. */
class RecGfx : Gfx {
    private var ops = JSONArray()

    fun result(): JSONArray = ops

    private fun segs(p: Path2D) = JSONArray().also { a ->
        for (s in p.segs) a.put(
            when (s) {
                is Seg.MoveTo -> arr("M", s.x, s.y)
                is Seg.LineTo -> arr("L", s.x, s.y)
                is Seg.QuadTo -> arr("Q", s.cx, s.cy, s.x, s.y)
                is Seg.CubicTo -> arr("C", s.c1x, s.c1y, s.c2x, s.c2y, s.x, s.y)
                is Seg.ArcTo -> arr("AT", s.x1, s.y1, s.x2, s.y2, s.r)
                is Seg.Arc -> arr("A", s.x, s.y, s.r, s.a0, s.a1)
                is Seg.Ellipse -> arr("E", s.x, s.y, s.rx, s.ry, s.rot, s.a0, s.a1)
                is Seg.Rect -> arr("R", s.x, s.y, s.w, s.h)
                Seg.Close -> arr("Z")
            },
        )
    }

    private fun rgba(c: Rgba) = listOf(c.r, c.g, c.b, c.a)
    private fun stops(l: List<Stop>) = JSONArray().also { a -> l.forEach { a.put(JSONArray(listOf(it.offset) + rgba(it.c))) } }
    private fun style(s: Style): JSONArray = when (s) {
        is Solid -> JSONArray(listOf<Any>("solid") + rgba(s.c))
        is LinearGradient -> JSONArray(listOf<Any>("lin", s.x0, s.y0, s.x1, s.y1, stops(s.stops)))
        is RadialGradient -> JSONArray(listOf<Any>("rad", s.x, s.y, s.r0, s.r1, stops(s.stops)))
    }

    private fun arr(vararg v: Any) = JSONArray(v.toList())

    override fun save() { ops.put(arr("save")) }
    override fun restore() { ops.put(arr("restore")) }
    override fun translate(x: Double, y: Double) { ops.put(arr("translate", x, y)) }
    override fun scale(x: Double, y: Double) { ops.put(arr("scale", x, y)) }
    override fun rotate(angle: Double) { ops.put(arr("rotate", angle)) }
    override fun clip(path: Path2D, evenOdd: Boolean) { ops.put(arr("clip", segs(path), evenOdd)) }
    override fun fill(path: Path2D, style: Style) { ops.put(arr("fill", segs(path), style(style))) }
    override fun stroke(path: Path2D, style: Style, width: Double, cap: Cap, join: Join) {
        ops.put(arr("stroke", segs(path), style(style), width, cap.name.lowercase(), join.name.lowercase()))
    }
    override fun layer(alpha: Double, block: () -> Unit) {
        val outer = ops
        ops = JSONArray()
        block()
        val inner = ops
        ops = outer
        ops.put(arr("layer", alpha, inner))
    }
}

/**
 * The Kotlin outfits against the TypeScript ones: android/tools/outfit-trace.mjs runs windows/src/mochi/outfits.ts
 * on 297 cases (every outfit, five head poses, the fade and drop-in states, the wardrobe icons) and this test
 * replays the same cases with the port and compares every drawing call, number by number. Skipped without node.
 */
class OutfitParityTest {
    private fun node(): Boolean = try {
        ProcessBuilder("node", "--version").redirectErrorStream(true).start().also { it.inputStream.readBytes() }.waitFor() == 0
    } catch (_: Exception) { false }

    private fun trace(): JSONArray {
        assumeTrue("node not available", node())
        val setup = ReferenceFiles.file("windows/tests/setup.mjs").absolutePath
        val script = ReferenceFiles.file("android/tools/outfit-trace.mjs").absolutePath
        val out = File.createTempFile("outfit-trace", ".json")
        try {
            val p = ProcessBuilder("node", "--import", setup, script).redirectOutput(out).redirectError(ProcessBuilder.Redirect.INHERIT)
                .directory(ReferenceFiles.file("windows")).start()
            assertTrue("trace timed out", p.waitFor(120, TimeUnit.SECONDS))
            assertEquals("trace failed", 0, p.exitValue())
            return JSONArray(out.readText())
        } finally { out.delete() }
    }

    private fun replay(c: JSONObject): JSONArray {
        val rec = RecGfx()
        val ctx = Ctx2D(rec)
        val outfit = Outfit.entries.first { it.id == c.getString("outfit") }
        when (c.getString("kind")) {
            "icon" -> drawIconMochi(ctx, c.getDouble("size"), outfit)
            else -> {
                val hd = c.getJSONObject("head")
                val st = c.getJSONObject("state")
                val h = makeHead(hd.getDouble("R"), hd.getDouble("yaw"), hd.getDouble("pitch"), hd.getDouble("physDx"), hd.getDouble("physDy"))
                val s = OutfitState(st.getDouble("presence"), st.getDouble("morph"))
                if (c.getString("kind") == "behind") drawOutfitBehind(ctx, outfit, h, s) else drawOutfitFront(ctx, outfit, h, s)
            }
        }
        return rec.result()
    }

    private fun same(path: String, a: Any?, b: Any?) {
        when {
            a is JSONArray && b is JSONArray -> {
                assertEquals("$path length", a.length(), b.length())
                for (i in 0 until a.length()) same("$path[$i]", a.get(i), b.get(i))
            }
            a is Number && b is Number -> {
                val x = a.toDouble()
                val y = b.toDouble()
                assertTrue("$path: $x vs $y", abs(x - y) <= 1e-7 * maxOf(1.0, abs(x), abs(y)))
            }
            else -> assertEquals(path, a, b)
        }
    }

    @Test fun everyDrawingCallMatchesTheTypeScriptOriginal() {
        val cases = trace()
        assertTrue(cases.length() > 250)
        var compared = 0
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val label = "${c.getString("kind")} ${c.getString("outfit")} " + (c.optJSONObject("head")?.toString() ?: "") + (c.optJSONObject("state")?.toString() ?: "")
            same(label, c.getJSONArray("ops"), replay(c))
            compared += c.getJSONArray("ops").length()
        }
        assertTrue("only $compared calls compared", compared > 3_000)
    }

    @Test fun theTraceReallyDrawsSomething() {
        val cases = trace()
        val byOutfit = HashMap<String, Int>()
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            if (c.getString("kind") == "front" && c.getJSONArray("ops").length() > 0) byOutfit.merge(c.getString("outfit"), 1, Int::plus)
        }
        // Every outfit but the bunny ears (all of them behind the head) has a front.
        assertEquals(10, byOutfit.size)
    }
}
