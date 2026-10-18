package fr.louisraille.coucou.phone

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class UrgencyTest {
    @Test
    fun rankedLikeTheMacsLiveActivity() {
        val order = listOf("approval", "question", "error", "working", "finished", "idle")
        val ranks = order.map(::urgencyOf)
        assertEquals(ranks.sortedDescending(), ranks)
        assertEquals(urgencyOf("error"), urgencyOf("ratelimit"))
        assertEquals(urgencyOf("error"), urgencyOf("dizzy"))
        assertEquals(urgencyOf("working"), urgencyOf("thinking"))
        assertEquals(urgencyOf("working"), urgencyOf("searching"))
        assertTrue(urgencyOf("question") >= 4) // still bold in the list (Screens.kt)
    }
}
