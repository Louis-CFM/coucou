package fr.louisraille.coucou.phone

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class QuestionAnswersTest {
    private val single = Relay.Question("Which one?", listOf("A", "B"))
    private val multi = Relay.Question("Extras?", listOf("Tests", "Docs"), multi = true)

    @Test
    fun aSingleChoiceKeepsOnlyTheLastTap() {
        assertEquals(listOf("B"), QuestionAnswers.toggle(listOf("A"), "B", multi = false))
    }

    @Test
    fun aMultiChoiceTogglesEachOption() {
        var p = emptyList<String>()
        p = QuestionAnswers.toggle(p, "Tests", multi = true)
        p = QuestionAnswers.toggle(p, "Docs", multi = true)
        assertEquals(listOf("Tests", "Docs"), p)
        p = QuestionAnswers.toggle(p, "Tests", multi = true)
        assertEquals(listOf("Docs"), p)
    }

    @Test
    fun answersAreALabelOrAListAsTheHookTakesThem() {
        val picked = mapOf("Which one?" to listOf("B"), "Extras?" to listOf("Tests", "Docs"))
        assertTrue(QuestionAnswers.complete(listOf(single, multi), picked))
        assertEquals(
            mapOf("Which one?" to "B", "Extras?" to listOf("Tests", "Docs")),
            QuestionAnswers.toAnswers(listOf(single, multi), picked),
        )
        assertFalse(QuestionAnswers.complete(listOf(single, multi), mapOf("Which one?" to listOf("B"))))
    }

    @Test
    fun wordsUnderOtherAnswerTheQuestionAndListIt() {
        val groups = listOf(single, multi)
        val picked = mapOf("Extras?" to listOf("Tests"))
        val other = mapOf("Which one?" to "the third thing")
        assertTrue(QuestionAnswers.complete(groups, picked, other))
        assertEquals(
            mapOf("Which one?" to "the third thing", "Extras?" to listOf("Tests")),
            QuestionAnswers.toAnswers(groups, picked, other),
        )
        assertEquals(listOf("Which one?"), QuestionAnswers.others(groups, other))
        // Blank words do not count as an answer.
        assertFalse(QuestionAnswers.complete(groups, picked, mapOf("Which one?" to "  ")))
    }
}
