package com.coucou.android.link

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The chat part of the wire format, and that nothing else about it changed. */
class ProtocolChatTest {
    @Test fun aHelloWithNoCapsIsExactlyTheOldHello() {
        val o = JSONObject(Wire.encode(ClientMsg.Hello(1, "tok", "Pixel")))
        assertEquals(setOf("type", "v", "token", "device"), o.keys().asSequence().toSet())
    }

    @Test fun aHelloAsksForTheOptionalFeaturesTheAppHas() {
        val o = JSONObject(Wire.encode(ClientMsg.Hello(1, "tok", "Pixel", Protocol.CAPABILITIES)))
        assertEquals(listOf("chat", "details", "answers", "prefs", "diffs", "usage", "services", "relay"), (0 until o.getJSONArray("caps").length()).map { o.getJSONArray("caps").getString(it) })
    }

    @Test fun aWelcomeWithoutCapsOffersNothing() {
        val w = Wire.decodeServer("""{"type":"welcome","v":1,"desktop":"PC","os":"windows"}""") as ServerMsg.Welcome
        assertEquals(emptySet<String>(), w.caps)
    }

    @Test fun aWelcomeOffersTheCapsItNames_ignoringJunk() {
        val w = Wire.decodeServer("""{"type":"welcome","v":1,"desktop":"PC","os":"x","caps":["chat","details",5,"",null]}""") as ServerMsg.Welcome
        assertTrue("chat" in w.caps && "details" in w.caps)
        assertFalse("" in w.caps)
        val odd = Wire.decodeServer("""{"type":"welcome","v":1,"desktop":"PC","os":"x","caps":"chat"}""") as ServerMsg.Welcome
        assertEquals(emptySet<String>(), odd.caps)
    }

    @Test fun chatMessagesToTheComputer() {
        assertEquals("""{"type":"chatModels"}""", Wire.encode(ClientMsg.ChatModels))
        assertEquals("""{"type":"chatReset"}""", Wire.encode(ClientMsg.ChatReset))
        val send = JSONObject(Wire.encode(ClientMsg.ChatSend("c1", "openai/gpt", "héllo \"q\"\nnew line")))
        assertEquals("chatSend", send.getString("type"))
        assertEquals("c1", send.getString("id"))
        assertEquals("openai/gpt", send.getString("model"))
        assertEquals("héllo \"q\"\nnew line", send.getString("text"))
        assertFalse("a message is one line", Wire.encode(ClientMsg.ChatSend("c1", "m/x", "a\nb")).contains('\n'))
        assertEquals("c9", JSONObject(Wire.encode(ClientMsg.ChatCancel("c9"))).getString("id"))
    }

    @Test fun theModelListKeepsIdsProvidersAndLabels() {
        val m = Wire.decodeServer(
            """{"type":"chatModels","models":[{"id":"openai/gpt-4o","provider":"openai","label":"OpenAI · gpt-4o"},{"id":"ollama/llama3"},{"id":"noslash"},{"id":""},{"label":"x"}]}""",
        ) as ServerMsg.ChatModels
        assertEquals(
            listOf(ChatModel("openai/gpt-4o", "openai", "OpenAI · gpt-4o"), ChatModel("ollama/llama3", "ollama", "ollama/llama3")),
            m.models,
        )
        assertEquals(emptyList<ChatModel>(), (Wire.decodeServer("""{"type":"chatModels","models":[]}""") as ServerMsg.ChatModels).models)
    }

    @Test fun anAnswerArrivesAsDeltasThenDoneOrAnError() {
        assertEquals(ServerMsg.ChatDelta("c1", "Hel"), Wire.decodeServer("""{"type":"chatDelta","id":"c1","text":"Hel"}"""))
        assertEquals(ServerMsg.ChatDone("c1", null), Wire.decodeServer("""{"type":"chatDone","id":"c1"}"""))
        assertEquals(ServerMsg.ChatDone("c1", "Full"), Wire.decodeServer("""{"type":"chatDone","id":"c1","text":"Full"}"""))
        assertEquals(
            ServerMsg.ChatError("c1", "rate", "Too many messages."),
            Wire.decodeServer("""{"type":"chatError","id":"c1","reason":"rate","message":"Too many messages."}"""),
        )
        // a reason the app does not know is kept as it is; a missing one is "internal"
        assertEquals("internal", (Wire.decodeServer("""{"type":"chatError","id":"c1"}""") as ServerMsg.ChatError).reason)
    }

    @Test fun malformedChatLinesNeverThrow() {
        for (bad in listOf(
            """{"type":"chatDelta","id":"c1"}""", """{"type":"chatDelta","text":"x"}""", """{"type":"chatDelta","id":"","text":"x"}""",
            """{"type":"chatDelta","id":"a b","text":"x"}""", """{"type":"chatDelta","id":"${"a".repeat(65)}","text":"x"}""",
            """{"type":"chatDone"}""", """{"type":"chatError","reason":"x"}""", """{"type":"chatModels"}""", """{"type":"chatModels","models":5}""",
        )) assertNull(bad, Wire.decodeServer(bad))
    }

    @Test fun chatIds() {
        for (ok in listOf("c1", "abc-DEF_09", "a".repeat(64))) assertTrue(ok, Wire.isChatId(ok))
        for (bad in listOf("", "a b", "é", "a/b", "a".repeat(65), "a\n")) assertFalse(bad, Wire.isChatId(bad))
    }
}
