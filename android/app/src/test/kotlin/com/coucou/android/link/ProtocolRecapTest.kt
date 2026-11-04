package com.coucou.android.link

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProtocolRecapTest {
    private fun recap(json: String) = (Wire.decodeServer(json) as ServerMsg.RecapMsg).recap
    private val full = """{"type":"recap","week":"2026-10-05","minutes":340,"sessions":12,"files":40,"added":900,"removed":210,"commands":55,"allowed":20,"denied":3,"topAgent":"Claude Code"}"""

    @Test fun theWeekIsRead() {
        val r = recap(full)!!
        assertEquals(Recap("2026-10-05", 340, 12, 40, 900, 210, 55, 20, 3, "Claude Code", null), r)
    }

    @Test fun theProjectIsAFolderNameEvenIfAPathWereSent() {
        assertEquals("coucou", recap(full.replace("}", ""","project":"/home/someone/private/coucou"}"""))!!.project)
        assertNull(recap(full.replace("}", ""","project":"/"}"""))!!.project)
    }

    @Test fun aBareMessageTakesTheCardAway() {
        assertNull(recap("""{"type":"recap"}"""))
    }

    @Test fun anythingOutOfRangeOrNotAWholeNumberDropsTheCard() {
        for (bad in listOf(
            full.replace("\"minutes\":340", "\"minutes\":10081"), full.replace("\"files\":40", "\"files\":-1"),
            full.replace("\"files\":40", "\"files\":4.5"), full.replace("\"files\":40", "\"files\":\"40\""),
            full.replace("\"sessions\":12", "\"sessions\":0"), full.replace("\"sessions\":12,", ""),
            full.replace("2026-10-05", "2026-13-05"), full.replace("2026-10-05", "<script>1"), full.replace("\"denied\":3", "\"denied\":10000001"),
        )) assertNull(bad, recap(bad))
    }

    @Test fun theAgentNameIsPlainAndShort() {
        assertEquals("Claude Codeb", recap(full.replace("Claude Code", "Claude Code\\n<b>"))!!.topAgent)
        assertEquals(24, recap(full.replace("Claude Code", "A".repeat(80)))!!.topAgent!!.length)
        assertNull(recap(full.replace("Claude Code", "<>\\n"))!!.topAgent)
    }

    @Test fun theHelloAsksForTheRecap() {
        assertTrue(Protocol.CAP_RECAP in Protocol.CAPABILITIES)
    }
}
