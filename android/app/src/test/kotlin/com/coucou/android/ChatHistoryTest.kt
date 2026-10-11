package com.coucou.android

import com.coucou.android.core.ChatHistory
import com.coucou.android.core.ChatMessage
import com.coucou.android.core.ChatRole
import com.coucou.android.core.ChatSession
import com.coucou.android.core.ChatStatus
import com.coucou.android.core.TextFile
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatHistoryTest {
    private class Mem(var text: String? = null) : TextFile {
        override fun read() = text
        override fun write(text: String) { this.text = text }
        override fun delete() { text = null }
    }

    private val sample = listOf(
        ChatMessage("u-c1", ChatRole.USER, "Hello \"there\"\nsecond line é"),
        ChatMessage("c1", ChatRole.ASSISTANT, "Hi!", ChatStatus.DONE),
        ChatMessage("u-c2", ChatRole.USER, "again"),
        ChatMessage("c2", ChatRole.ASSISTANT, "part", ChatStatus.FAILED, "rate"),
    )

    @Test fun whatIsSavedComesBack() {
        val h = ChatHistory(Mem())
        h.save(sample)
        assertEquals(sample, h.load())
    }

    @Test fun savingNothingRemovesTheFile() {
        val m = Mem()
        val h = ChatHistory(m)
        h.save(sample)
        assertTrue(m.text != null)
        h.save(emptyList())
        assertNull(m.text)
        assertEquals(emptyList<ChatMessage>(), h.load())
    }

    @Test fun clearDeletesTheFile() {
        val m = Mem()
        val h = ChatHistory(m)
        h.save(sample)
        h.clear()
        assertNull(m.text)
    }

    @Test fun aDamagedOrUnknownFileIsAnEmptyHistory() {
        for (bad in listOf("", "   ", "not json", "{}", """{"v":2,"messages":[]}""", """{"v":1}""", """{"v":1,"messages":5}""", "[]")) {
            assertEquals(bad, emptyList<ChatMessage>(), ChatHistory(Mem(bad)).load())
        }
    }

    @Test fun badEntriesAreSkippedAndTheRestKept() {
        val text = """{"v":1,"messages":[5,{"id":"","role":"user","text":"x"},{"id":"a","role":"alien","text":"x"},{"id":"ok","role":"user","text":"kept"}]}"""
        assertEquals(listOf(ChatMessage("ok", ChatRole.USER, "kept")), ChatHistory(Mem(text)).load())
    }

    @Test fun anAnswerThatWasStillArrivingIsShownAsInterrupted() {
        val h = ChatHistory(Mem())
        h.save(listOf(ChatMessage("c1", ChatRole.ASSISTANT, "half", ChatStatus.STREAMING)))
        val m = h.load().single()
        assertEquals(ChatStatus.FAILED, m.status)
        assertEquals("interrupted", m.reason)
        assertEquals("half", m.text)
    }

    @Test fun onlyTheLastTwoHundredAreKept() {
        val many = (1..300).map { ChatMessage("m$it", ChatRole.USER, "t$it") }
        val h = ChatHistory(Mem())
        h.save(many)
        val back = h.load()
        assertEquals(ChatSession.MAX_MESSAGES, back.size)
        assertEquals("m300", back.last().id)
    }

    @Test fun theFileHoldsTheChatAndNothingElse() {
        // No key, address or model list is ever in a ChatMessage, so none can be in the file.
        val m = Mem()
        ChatHistory(m).save(sample)
        assertFalse(m.text!!.contains("token", ignoreCase = true))
        assertTrue(m.text!!.length < 2000)
    }
}
