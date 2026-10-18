package com.coucou.android.link

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProtocolAnswersTest {
    private val fp = "ab".repeat(32)

    private fun question(vararg q: String, extra: String = "") =
        """{"type":"question","pillId":"integration_claude","fingerprint":"$fp","createdAt":1700000000000,"questions":[${q.joinToString(",")}]$extra}"""

    private fun q(text: String, vararg labels: String, multi: Boolean = false) =
        """{"question":"$text","multiSelect":$multi,"options":[${labels.joinToString(",") { """{"label":"$it","description":"about $it"}""" }}]}"""

    @Test fun aQuestionIsDecodedWithItsOptions() {
        val m = Wire.decodeServer(question(q("Which?", "A", "B"), q("Extras?", "X", "Y", multi = true))) as ServerMsg.Question
        assertEquals("integration_claude", m.request.pillId)
        assertEquals(fp, m.request.fingerprint)
        assertEquals(2, m.request.questions.size)
        assertEquals(listOf("A", "B"), m.request.questions[0].options.map { it.label })
        assertEquals("about A", m.request.questions[0].options[0].description)
        assertTrue(m.request.questions[1].multiSelect)
        assertFalse(m.request.questions[0].multiSelect)
    }

    @Test fun aQuestionThatBreaksTheLimitsIsDroppedNotCrashed() {
        assertNull("no questions", Wire.decodeServer(question()))
        assertNull("no option", Wire.decodeServer(question(q("Which?"))))
        assertNull("twin labels", Wire.decodeServer(question(q("Which?", "A", "A"))))
        assertNull("blank label", Wire.decodeServer(question(q("Which?", "A", " "))))
        assertNull("blank question", Wire.decodeServer(question(q(" ", "A"))))
        assertNull("too many questions", Wire.decodeServer(question(*Array(5) { q("Q$it?", "A") })))
        assertNull("too many options", Wire.decodeServer(question(q("Which?", *Array(9) { "o$it" }))))
        assertNull("not a fingerprint", Wire.decodeServer(question(q("Which?", "A")).replace(fp, "nope")))
        assertNull("wrong shape", Wire.decodeServer("""{"type":"question","pillId":"p","fingerprint":"$fp","questions":"x"}"""))
    }

    @Test fun anAnswerIsOneListOfLabelsPerQuestionAndNothingElse() {
        val line = Wire.encode(ClientMsg.Answer(fp, listOf(listOf("B"), listOf("X", "Y"))))
        val o = JSONObject(line)
        assertEquals("answer", o.getString("type"))
        assertEquals(fp, o.getString("fingerprint"))
        assertEquals("""[["B"],["X","Y"]]""", o.getJSONArray("picks").toString())
        assertEquals(setOf("type", "fingerprint", "picks"), o.keys().asSequence().toSet())
    }

    @Test fun theHelloAsksForAnswersAmongTheOtherCapabilities() {
        assertTrue(Protocol.CAP_ANSWERS in Protocol.CAPABILITIES)
        val hello = JSONObject(Wire.encode(ClientMsg.Hello(1, "T".repeat(20), "Phone", Protocol.CAPABILITIES)))
        assertTrue(hello.getJSONArray("caps").toString().contains("answers"))
        // an app asking for nothing sends the v1 hello unchanged
        assertFalse(JSONObject(Wire.encode(ClientMsg.Hello(1, "T".repeat(20), "Phone"))).has("caps"))
    }

    @Test fun anOldComputerThatSendsNoQuestionChangesNothing() {
        // unknown to an old phone, ignored by a new one when it was not offered (see LinkAnswersTest)
        assertEquals(setOf("chat", "details", "answers", "prefs", "diffs", "usage", "services", "relay"), Protocol.CAPABILITIES.toSet())
    }
}
