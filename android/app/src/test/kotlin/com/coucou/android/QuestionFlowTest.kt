package com.coucou.android

import com.coucou.android.core.QuestionFlow
import com.coucou.android.core.QuestionState
import com.coucou.android.link.AskedOption
import com.coucou.android.link.AskedQuestion
import com.coucou.android.link.Protocol
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class QuestionFlowTest {
    private fun opts(vararg l: String) = l.map { AskedOption(it, "") }
    private val single = AskedQuestion("Which engine?", opts("Postgres", "Meilisearch", "Algolia"), multiSelect = false)
    private val multi = AskedQuestion("Which extras?", opts("Typos", "Facets", "Synonyms"), multiSelect = true)
    private val both = listOf(single, multi)

    @Test fun aSingleChoiceKeepsOnlyTheLastTap() {
        var s = QuestionFlow.start(both)
        s = QuestionFlow.toggle(both, s, "Postgres")
        s = QuestionFlow.toggle(both, s, "Algolia")
        assertEquals(listOf("Algolia"), s.picks[0])
    }

    @Test fun aMultipleChoiceAddsAndRemovesAndKeepsTheOptionsOrder() {
        var s = QuestionFlow.next(both, QuestionFlow.toggle(both, QuestionFlow.start(both), "Meilisearch"))
        assertEquals(1, s.index)
        s = QuestionFlow.toggle(both, s, "Synonyms")
        s = QuestionFlow.toggle(both, s, "Typos")
        assertEquals("order of the options, not of the taps", listOf("Typos", "Synonyms"), s.picks[1])
        s = QuestionFlow.toggle(both, s, "Synonyms")
        assertEquals(listOf("Typos"), s.picks[1])
        s = QuestionFlow.toggle(both, s, "Typos")
        assertTrue(s.picks[1].isEmpty())
    }

    @Test fun aLabelThatIsNotAnOptionNeverEntersAnAnswer() {
        val s = QuestionFlow.start(both)
        assertEquals(s, QuestionFlow.toggle(both, s, "Mongo"))
        assertEquals(s, QuestionFlow.toggle(both, s, "postgres"))
        assertEquals(s, QuestionFlow.toggle(both, s, ""))
    }

    @Test fun youCannotMoveOnWithoutAnAnswer() {
        val s = QuestionFlow.start(both)
        assertFalse(QuestionFlow.canAdvance(both, s))
        assertEquals(s, QuestionFlow.next(both, s))
        val picked = QuestionFlow.toggle(both, s, "Postgres")
        assertTrue(QuestionFlow.canAdvance(both, picked))
        assertEquals(1, QuestionFlow.next(both, picked).index)
    }

    @Test fun theLastQuestionDoesNotAdvanceAndBackStopsAtTheFirst() {
        var s = QuestionFlow.toggle(both, QuestionFlow.start(both), "Postgres")
        s = QuestionFlow.next(both, s)
        assertTrue(QuestionFlow.isLast(both, s))
        s = QuestionFlow.toggle(both, s, "Facets")
        assertEquals(s, QuestionFlow.next(both, s))
        assertEquals(0, QuestionFlow.back(QuestionFlow.back(s)).index)
        assertEquals("the pick of the first question is kept", listOf("Postgres"), QuestionFlow.back(s).picks[0])
    }

    @Test fun anAnswerIsCompleteOnlyWhenEveryQuestionHasItsPicks() {
        var s = QuestionFlow.start(both)
        assertNull(QuestionFlow.picks(both, s))
        s = QuestionFlow.toggle(both, s, "Postgres")
        assertFalse(QuestionFlow.complete(both, s))
        s = QuestionFlow.toggle(both, QuestionFlow.next(both, s), "Typos")
        assertTrue(QuestionFlow.complete(both, s))
        assertEquals(listOf(listOf("Postgres"), listOf("Typos")), QuestionFlow.picks(both, s))
    }

    @Test fun twoPicksForASingleChoiceOrDuplicatesAreNotComplete() {
        assertFalse(QuestionFlow.complete(listOf(single), QuestionState(0, listOf(listOf("Postgres", "Algolia")))))
        assertFalse(QuestionFlow.complete(listOf(multi), QuestionState(0, listOf(listOf("Typos", "Typos")))))
        assertFalse(QuestionFlow.complete(listOf(multi), QuestionState(0, listOf(listOf("Nope")))))
        assertFalse(QuestionFlow.complete(listOf(single), QuestionState(0, listOf(emptyList()))))
        assertFalse(QuestionFlow.complete(both, QuestionState(0, listOf(listOf("Postgres")))))
    }

    @Test fun theLockPromptShowsWhatIsAboutToBeSent() {
        var s = QuestionFlow.toggle(both, QuestionFlow.start(both), "Meilisearch")
        s = QuestionFlow.toggle(both, QuestionFlow.next(both, s), "Typos")
        s = QuestionFlow.toggle(both, s, "Facets")
        assertEquals("Meilisearch; Typos, Facets", QuestionFlow.summary(both, s))
    }

    @Test fun aQuestionIsOfferedForTheSameTimeAsAnApproval() {
        assertFalse(QuestionFlow.expired(1_000, 1_000 + Protocol.APPROVAL_TTL_MS))
        assertTrue(QuestionFlow.expired(1_000, 1_001 + Protocol.APPROVAL_TTL_MS))
    }

    @Test fun onlyAMultiPartQuestionShowsAPosition() {
        assertNull(QuestionFlow.position(listOf(single), QuestionFlow.start(listOf(single))))
        assertEquals(1 to 2, QuestionFlow.position(both, QuestionFlow.start(both)))
    }
}
