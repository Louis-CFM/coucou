package com.coucou.android.link

import com.coucou.android.mochi.BotState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Session details (cap `details`) on the wire, and that a v1 session still reads exactly as before. */
class ProtocolDetailsTest {
    private fun session(json: String): SessionInfo =
        (Wire.decodeServer("""{"type":"sessions","sessions":[$json]}""") as ServerMsg.Sessions).sessions.single()

    @Test fun aV1SessionHasNoDetails() {
        val s = session("""{"pillId":"agent_codex","agent":"Codex","state":"working","statusText":"Editing","stepIndex":2,"stepCount":5,"updatedAt":1700}""")
        assertEquals(emptyList<String>(), s.steps)
        assertNull(s.finalLine); assertNull(s.project); assertNull(s.color)
        assertEquals(BotState.WORKING, s.state)
    }

    @Test fun detailsAreReadWhenPresent() {
        val s = session(
            """{"pillId":"p","state":"finished","steps":["Read · a.rs","Edit · a.rs"],"finalLine":"All done","project":"coucou","color":"#2DD4BF"}""",
        )
        assertEquals(listOf("Read · a.rs", "Edit · a.rs"), s.steps)
        assertEquals("All done", s.finalLine)
        assertEquals("coucou", s.project)
        assertEquals("#2DD4BF", s.color)
    }

    @Test fun theWelcomeNamesDetails() {
        val w = Wire.decodeServer("""{"type":"welcome","v":1,"desktop":"PC","os":"x","caps":["details"]}""") as ServerMsg.Welcome
        assertTrue(Protocol.CAP_DETAILS in w.caps && Protocol.CAP_CHAT !in w.caps)
    }

    @Test fun aProjectIsNeverAPathEvenIfTheComputerSendsOne() {
        for ((raw, want) in listOf(
            "/home/me/secret/app" to "app", "C:\\Users\\me\\app" to "app", "C:\\Users\\me\\app\\" to "app", "app/" to "app", "app" to "app",
        )) {
            val s = session("""{"pillId":"p","project":${org.json.JSONObject.quote(raw)}}""")
            assertEquals(raw, want, s.project)
        }
        for (none in listOf("", "/", "..", "/a/..", ".", "   ")) {
            assertNull(none, session("""{"pillId":"p","project":${org.json.JSONObject.quote(none)}}""").project)
        }
        assertEquals(Protocol.MAX_PROJECT_CHARS, session("""{"pillId":"p","project":"${"x".repeat(300)}"}""").project!!.length)
    }

    @Test fun onlyASixDigitColourIsKept() {
        for (ok in listOf("#8AB4F8", "#000000", "#abcdef")) assertEquals(ok, session("""{"pillId":"p","color":"$ok"}""").color)
        for (bad in listOf("", "red", "8AB4F8", "#12", "#GGGGGG", "#12345678", "url(x)")) assertNull(bad, session("""{"pillId":"p","color":"$bad"}""").color)
    }

    @Test fun stepsAreCappedAndOddEntriesSkipped() {
        val many = (1..40).joinToString(",") { "\"s$it\"" }
        val s = session("""{"pillId":"p","steps":[$many,5,null,"",{"a":1},"${"x".repeat(500)}"]}""")
        assertEquals(Protocol.MAX_STEPS, s.steps.size)
        assertEquals("s1", s.steps.first())
        val long = session("""{"pillId":"p","steps":["${"y".repeat(500)}"]}""").steps.single()
        assertEquals(Protocol.MAX_STEP_CHARS, long.length)
        assertEquals(emptyList<String>(), session("""{"pillId":"p","steps":"not a list"}""").steps)
    }

    @Test fun anEmptyFinalLineIsNoFinalLine() {
        assertNull(session("""{"pillId":"p","finalLine":"   "}""").finalLine)
        assertFalse(session("""{"pillId":"p","finalLine":"x"}""").finalLine.isNullOrBlank())
    }
}
