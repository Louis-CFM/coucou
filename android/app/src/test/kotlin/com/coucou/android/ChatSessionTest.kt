package com.coucou.android

import com.coucou.android.core.ChatIds
import com.coucou.android.core.ChatModels
import com.coucou.android.core.ChatRole
import com.coucou.android.core.ChatSession
import com.coucou.android.core.ChatSession.Refusal
import com.coucou.android.core.ChatSession.Sent
import com.coucou.android.core.ChatStatus
import com.coucou.android.link.ChatModel
import com.coucou.android.link.Protocol
import com.coucou.android.link.Wire
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatSessionTest {
    private var n = 0
    private fun session() = ChatSession(newId = { "c${++n}" })

    private fun ChatSession.ask(text: String = "hi", model: String? = "openai/gpt", connected: Boolean = true) = send(text, model, connected)

    @Test fun aQuestionIsSentOnceAndShowsUpTwiceOnScreen() {
        val s = session()
        val sent = s.ask("  Why is the sky blue?  ") as Sent.Ok
        assertEquals("c1", sent.msg.id)
        assertEquals("openai/gpt", sent.msg.model)
        assertEquals("Why is the sky blue?", sent.msg.text)
        assertEquals("c1", s.running)
        assertEquals(listOf(ChatRole.USER, ChatRole.ASSISTANT), s.messages.map { it.role })
        assertEquals(ChatStatus.STREAMING, s.messages[1].status)
        assertEquals("", s.messages[1].text)
    }

    @Test fun refusalsChangeNothing() {
        val s = session()
        assertEquals(Refusal.EMPTY, (s.ask("   ") as Sent.No).why)
        assertEquals(Refusal.TOO_LONG, (s.ask("x".repeat(Protocol.CHAT_MAX_TEXT + 1)) as Sent.No).why)
        assertEquals(Refusal.NO_MODEL, (s.ask(model = null) as Sent.No).why)
        assertEquals(Refusal.NO_MODEL, (s.ask(model = " ") as Sent.No).why)
        assertEquals(Refusal.OFFLINE, (s.ask(connected = false) as Sent.No).why)
        assertTrue(s.messages.isEmpty())
        assertNull(s.running)
        assertTrue(s.ask("x".repeat(Protocol.CHAT_MAX_TEXT)) is Sent.Ok)
    }

    @Test fun onlyOneAnswerAtATime() {
        val s = session()
        s.ask("one")
        assertEquals(Refusal.BUSY, (s.ask("two") as Sent.No).why)
        assertEquals(2, s.messages.size)
    }

    @Test fun deltasBuildTheAnswerAndDoneEndsIt() {
        val s = session()
        s.ask()
        s.onDelta("c1", "Hel"); s.onDelta("c1", "lo")
        assertEquals("Hello", s.messages[1].text)
        assertEquals(ChatStatus.STREAMING, s.messages[1].status)
        s.onDone("c1", null)
        assertEquals("Hello", s.messages[1].text)
        assertEquals(ChatStatus.DONE, s.messages[1].status)
        assertNull(s.running)
        assertTrue(s.ask("next") is Sent.Ok)
    }

    @Test fun aCorrectedAnswerReplacesTheStreamedOne() {
        val s = session()
        s.ask()
        s.onDelta("c1", "<think>hmm")
        s.onDone("c1", "Answer")
        assertEquals("Answer", s.messages[1].text)
    }

    @Test fun anErrorKeepsWhatArrivedAndSaysWhy() {
        val s = session()
        s.ask()
        s.onDelta("c1", "partial")
        s.onError("c1", "provider")
        with(s.messages[1]) {
            assertEquals("partial", text); assertEquals(ChatStatus.FAILED, status); assertEquals("provider", reason)
        }
        assertNull(s.running)
    }

    @Test fun cancelStopsWaitingAtOnceAndLateWordsAreIgnored() {
        val s = session()
        s.ask()
        s.onDelta("c1", "a")
        assertEquals("c1", s.cancel())
        assertEquals("canceled", s.messages[1].reason)
        s.onDelta("c1", "late"); s.onDone("c1", "late"); s.onError("c1", "rate")
        assertEquals("a", s.messages[1].text)
        assertEquals("canceled", s.messages[1].reason)
        assertNull(s.cancel())
    }

    @Test fun wordsForAnotherRequestChangeNothing() {
        val s = session()
        s.ask()
        s.onDelta("other", "x"); s.onDone("other", "y"); s.onError("other", "auth")
        assertEquals("", s.messages[1].text)
        assertEquals("c1", s.running)
    }

    @Test fun aDroppedLinkEndsTheWaitWithoutLosingTheText() {
        val s = session()
        s.ask(); s.onDelta("c1", "half")
        s.onDisconnected()
        assertEquals("half", s.messages[1].text)
        assertEquals("connection", s.messages[1].reason)
        assertNull(s.running)
        s.onDisconnected() // nothing running: nothing happens
    }

    @Test fun clearForgetsEverythingAndStopsWaiting() {
        val s = session()
        s.ask(); s.onDone("c1", null); s.ask("again")
        s.clear()
        assertTrue(s.messages.isEmpty())
        assertNull(s.running)
        s.onDelta("c2", "late")
        assertTrue(s.messages.isEmpty())
    }

    @Test fun onlyTheLastTwoHundredMessagesAreKept() {
        val s = session()
        repeat(150) { s.ask("q$it"); s.onDone("c${it + 1}", null) }
        assertEquals(ChatSession.MAX_MESSAGES, s.messages.size)
        assertEquals("q149", s.messages[s.messages.size - 2].text)
    }

    @Test fun anAnswerCannotGrowWithoutLimit() {
        val s = session()
        s.ask()
        repeat(10) { s.onDelta("c1", "x".repeat(10_000)) }
        assertEquals(ChatSession.MAX_TEXT, s.messages[1].text.length)
    }

    @Test fun generatedIdsAreValidAndDifferent() {
        val ids = (1..200).map { ChatIds.random() }
        assertTrue(ids.all { Wire.isChatId(it) })
        assertEquals(200, ids.toSet().size)
    }

    @Test fun theModelStaysIfStillAllowedElseTheFirst() {
        val a = ChatModel("openai/a", "openai", "A")
        val b = ChatModel("google/b", "google", "B")
        assertEquals("google/b", ChatModels.pick(listOf(a, b), "google/b"))
        assertEquals("openai/a", ChatModels.pick(listOf(a, b), "gone/x"))
        assertEquals("openai/a", ChatModels.pick(listOf(a, b), null))
        assertNull(ChatModels.pick(emptyList(), "openai/a"))
    }
}
