package com.coucou.android

import com.coucou.android.core.DiffAssembler
import com.coucou.android.link.DiffRow
import com.coucou.android.link.ServerMsg
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DiffAssemblerTest {
    private fun part(i: Int, of: Int, n: Int, pill: String = "p", file: Long = 7, truncated: Boolean = false) = ServerMsg.Diff(
        pill, file, "app.ts", 5, 4, tooLarge = false, gone = false, truncated = truncated, part = i, parts = of,
        lines = (0 until n).map { DiffRow('+', "l$i-$it") },
    )

    @Test fun oneWholePartIsDone() {
        val a = DiffAssembler().apply { expect("p", 7) }
        val v = a.accept(part(0, 1, 3))
        assertNotNull(v)
        assertEquals(3, v!!.rows.size)
        assertEquals("app.ts", v.name)
        assertEquals(5, v.added)
    }

    @Test fun partsAreJoinedInOrder() {
        val a = DiffAssembler().apply { expect("p", 7) }
        assertNull(a.accept(part(0, 2, 100)))
        val v = a.accept(part(1, 2, 100))!!
        assertEquals(200, v.rows.size)
        assertEquals("l0-0", v.rows.first().text)
        assertEquals("l1-99", v.rows.last().text)
        assertFalse(v.truncated)
    }

    @Test fun nothingIsKeptAfterItIsDone() {
        val a = DiffAssembler().apply { expect("p", 7) }
        a.accept(part(0, 1, 2))
        assertNull("an unasked answer is dropped", a.accept(part(0, 1, 2)))
    }

    @Test fun whatWasNotAskedForIsDropped() {
        val a = DiffAssembler().apply { expect("p", 7) }
        assertNull(a.accept(part(0, 1, 2, pill = "other")))
        assertNull(a.accept(part(0, 1, 2, file = 8)))
        assertNotNull(a.accept(part(0, 1, 2)))
        assertNull(DiffAssembler().accept(part(0, 1, 2)))
    }

    @Test fun aPartOutOfOrderWaitsForAFreshStart() {
        val a = DiffAssembler().apply { expect("p", 7) }
        assertNull(a.accept(part(1, 2, 10)))
        assertNull(a.accept(part(0, 2, 10)))
        assertNotNull(a.accept(part(1, 2, 10)))
    }

    @Test fun cancelForgetsEverything() {
        val a = DiffAssembler().apply { expect("p", 7) }
        a.accept(part(0, 2, 100))
        a.cancel()
        assertNull(a.accept(part(1, 2, 100)))
    }

    @Test fun neverMoreThanTwoHundredRowsAndTheNoteSaysSo() {
        val a = DiffAssembler().apply { expect("p", 7) }
        a.accept(part(0, 3, 100))
        a.accept(part(1, 3, 100))
        val v = a.accept(part(2, 3, 100))!!
        assertEquals(200, v.rows.size)
        assertTrue(v.truncated)
    }
}
