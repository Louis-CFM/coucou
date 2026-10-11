package com.coucou.android.link

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProtocolUsageTest {
    private fun usage(json: String) = (Wire.decodeServer(json) as ServerMsg.Usage).usage

    @Test fun bothPlansAreRead() {
        val u = usage("""{"type":"usage","claude":{"fiveHour":{"pct":42,"resetsAt":1900000000000},"sevenDay":{"pct":7,"resetsAt":1900500000000},"updatedAt":5},"codex":{"sevenDay":{"pct":100,"resetsAt":1900500000000},"resetCredits":2,"plan":"plus"}}""")
        assertEquals(PlanWindow(42, 1_900_000_000_000), u.claude!!.fiveHour)
        assertEquals(PlanWindow(7, 1_900_500_000_000), u.claude!!.sevenDay)
        assertEquals(5L, u.claude!!.updatedAtMs)
        assertNull(u.codex!!.fiveHour)
        assertEquals(2, u.codex!!.resetCredits)
        assertEquals("plus", u.codex!!.plan)
    }

    @Test fun anEmptyMessageTakesTheUsageAway() {
        val u = usage("""{"type":"usage"}""")
        assertNull(u.claude)
        assertNull(u.codex)
    }

    @Test fun aPlanWithoutAUsableWindowIsLeftOut() {
        val u = usage("""{"type":"usage","claude":{"fiveHour":{"pct":101,"resetsAt":5},"sevenDay":{"pct":-1,"resetsAt":5}},"codex":{"fiveHour":{"pct":5}}}""")
        assertNull(u.claude)
        assertNull(u.codex)
    }

    @Test fun nonsenseAroundAWindowIsDroppedNotTrusted() {
        val u = usage("""{"type":"usage","claude":{"fiveHour":{"pct":10,"resetsAt":0},"sevenDay":{"pct":20,"resetsAt":9},"resetCredits":500,"plan":"<b>pro\n max</b>"}}""")
        assertNull(u.claude!!.fiveHour)
        assertEquals(PlanWindow(20, 9), u.claude!!.sevenDay)
        assertNull(u.claude!!.resetCredits)
        assertEquals("bpro maxb", u.claude!!.plan)
    }

    @Test fun theHelloAsksForUsage() {
        assertTrue(Protocol.CAP_USAGE in Protocol.CAPABILITIES)
    }
}
