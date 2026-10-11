package com.coucou.android

import com.coucou.android.core.HomePanel
import com.coucou.android.link.SessionInfo
import com.coucou.android.mochi.BotState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HomePanelTest {
    private fun s(id: String, st: BotState) = SessionInfo(id, id, st, "", 0, 0, 0L)

    @Test fun theAgentThatNeedsYouMostIsInTheBigCard() {
        val list = listOf(s("a", BotState.WORKING), s("b", BotState.APPROVAL), s("c", BotState.ERROR), s("d", BotState.IDLE))
        assertEquals("b", HomePanel.focus(list, null)!!.pillId)
        assertEquals("c", HomePanel.focus(list.filter { it.pillId != "b" }, null)!!.pillId)
        assertEquals("a", HomePanel.focus(listOf(s("d", BotState.IDLE), s("a", BotState.WORKING)), null)!!.pillId)
    }

    @Test fun onATieTheFirstOneWins() {
        assertEquals("a", HomePanel.focus(listOf(s("a", BotState.WORKING), s("b", BotState.WORKING)), null)!!.pillId)
    }

    @Test fun aTappedAgentStaysInTheCardWhileItExists() {
        val list = listOf(s("a", BotState.APPROVAL), s("b", BotState.IDLE))
        assertEquals("b", HomePanel.focus(list, "b")!!.pillId)
        assertEquals("a", HomePanel.focus(list, "gone")!!.pillId)
    }

    @Test fun noAgentMeansNoFocus() {
        assertNull(HomePanel.focus(emptyList(), null))
        assertNull(HomePanel.focus(emptyList(), "a"))
    }

    @Test fun theOthersExcludeTheFocusAndKeepTheirOrder() {
        val list = listOf(s("a", BotState.IDLE), s("b", BotState.IDLE), s("c", BotState.IDLE), s("d", BotState.IDLE), s("e", BotState.IDLE))
        val others = HomePanel.others(list, list[0])
        assertEquals(listOf("b", "c", "d", "e"), others.map { it.pillId })
        assertEquals(5, HomePanel.others(list, null).size)
    }

    @Test fun theLinkAnswersARequestFirstThenPairsThenIsGone() {
        assertEquals(HomePanel.Link.APPROVAL, HomePanel.link(paired = true, demo = false, hasApproval = true))
        assertEquals(HomePanel.Link.APPROVAL, HomePanel.link(paired = false, demo = true, hasApproval = true))
        assertEquals(HomePanel.Link.PAIR, HomePanel.link(paired = false, demo = false, hasApproval = false))
        // Settings is no longer a link on the card (it has its own button): nothing to show.
        assertEquals(HomePanel.Link.NONE, HomePanel.link(paired = true, demo = false, hasApproval = false))
        assertEquals(HomePanel.Link.NONE, HomePanel.link(paired = false, demo = true, hasApproval = false))
    }

    @Test fun pillColoursBecomeMochiBodies() {
        val c = HomePanel.rgb("#8AB4F8")!!
        assertEquals(0x8A / 255.0, c.r, 1e-9)
        assertEquals(0xB4 / 255.0, c.g, 1e-9)
        assertEquals(0xF8 / 255.0, c.b, 1e-9)
        assertNull(HomePanel.rgb("blue"))
        assertNull(HomePanel.rgb("#12"))
        assertNull(HomePanel.rgb("#GGGGGG"))
    }

    @Test fun theCardOpensOnlyWhenThereIsSomethingToShow() {
        assertTrue(!HomePanel.hasDetails(s("a", BotState.IDLE)))
        assertTrue(HomePanel.hasDetails(s("a", BotState.IDLE).copy(steps = listOf("x"))))
        assertTrue(HomePanel.hasDetails(s("a", BotState.IDLE).copy(finalLine = "done")))
        assertTrue(HomePanel.hasDetails(s("a", BotState.IDLE).copy(project = "app")))
        assertTrue(!HomePanel.hasDetails(s("a", BotState.IDLE).copy(finalLine = "  ", color = "#112233")))
    }

    @Test fun theUsersColourBeatsTheCatalogsAndTheCatalogIsTheFallback() {
        assertEquals("#2DD4BF", HomePanel.colorHex(s("agent_gemini", BotState.IDLE).copy(color = "#2DD4BF")))
        assertEquals("#8AB4F8", HomePanel.colorHex(s("agent_gemini", BotState.IDLE)))
        assertNull(HomePanel.colorHex(s("not_a_pill", BotState.IDLE)))
    }

    @Test fun stepsAreListedNewestFirst() {
        assertEquals(listOf("c", "b", "a"), HomePanel.stepsNewestFirst(s("a", BotState.IDLE).copy(steps = listOf("a", "b", "c"))))
    }
}
