package com.coucou.android.link

import com.coucou.android.mochi.BotState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProtocolTest {
    private val fp = "0b2944f472c9dda6c1d369e7c161730641be8e67174c8eb67c887a2fe0ccd30d"

    @Test fun fingerprintMatchesTheMacDerivation() {
        // Vector computed independently with Node's crypto over the U+001F-joined fields.
        assertEquals(fp, Fingerprint.of("agent_codex", "sess-1", "Bash", "rm -rf build", "k1"))
    }

    @Test fun fingerprintChangesWithAnyField() {
        val base = Fingerprint.of("p", "s", "t", "c", "i")
        assertFalse(base == Fingerprint.of("p", "s", "t", "c2", "i"))
        assertFalse(base == Fingerprint.of("p", "s2", "t", "c", "i"))
        // Field boundaries matter: moving text between fields is a different request.
        assertFalse(Fingerprint.of("a", "bc", "t", "c", "i") == Fingerprint.of("ab", "c", "t", "c", "i"))
    }

    @Test fun encodesClientMessages() {
        val d = org.json.JSONObject(Wire.encode(ClientMsg.Decision(fp, true)))
        assertEquals("decision", d.getString("type")); assertEquals(fp, d.getString("fingerprint")); assertEquals("allow", d.getString("decision"))
        assertTrue(Wire.encode(ClientMsg.Decision(fp, false)).contains(""""decision":"deny""""))
        assertEquals("ping", org.json.JSONObject(Wire.encode(ClientMsg.Ping)).getString("type"))
        val hello = Wire.encode(ClientMsg.Hello(1, "tok", "Pixel"))
        assertTrue(hello.contains(""""type":"hello"""") && hello.contains(""""token":"tok""""))
    }

    @Test fun decodesSessions() {
        val m = Wire.decodeServer(
            """{"type":"sessions","sessions":[{"pillId":"agent_codex","agent":"Codex","state":"working","statusText":"Editing","stepIndex":2,"stepCount":5,"updatedAt":1700}]}""",
        ) as ServerMsg.Sessions
        assertEquals(1, m.sessions.size)
        with(m.sessions[0]) {
            assertEquals("agent_codex", pillId)
            assertEquals(BotState.WORKING, state)
            assertEquals(2, stepIndex)
            assertEquals(5, stepCount)
        }
    }

    @Test fun unknownStateFallsBackToIdle() {
        val m = Wire.decodeServer("""{"type":"sessions","sessions":[{"pillId":"p","state":"levitating"}]}""") as ServerMsg.Sessions
        assertEquals(BotState.IDLE, m.sessions[0].state)
    }

    @Test fun decodesApprovalAndRejectsBadFingerprints() {
        val ok = Wire.decodeServer("""{"type":"approval","pillId":"p","fingerprint":"$fp","tool":"Bash","command":"ls","createdAt":5}""")
        assertTrue(ok is ServerMsg.Approval)
        assertNull(Wire.decodeServer("""{"type":"approval","pillId":"p","fingerprint":"nothex","tool":"Bash","command":"ls","createdAt":5}"""))
        assertNull(Wire.decodeServer("""{"type":"approval","pillId":"p","fingerprint":"${fp.uppercase()}","tool":"Bash","command":"ls","createdAt":5}"""))
    }

    @Test fun aCutCommandIsFlaggedAndAnOldComputerMeansNotCut() {
        val cut = Wire.decodeServer("""{"type":"approval","pillId":"p","fingerprint":"$fp","tool":"Bash","command":"ls","truncated":true,"createdAt":5}""") as ServerMsg.Approval
        assertTrue(cut.request.truncated)
        val whole = Wire.decodeServer("""{"type":"approval","pillId":"p","fingerprint":"$fp","tool":"Bash","command":"ls","truncated":false,"createdAt":5}""") as ServerMsg.Approval
        assertFalse(whole.request.truncated)
        // A computer from before the flag sends nothing: that is how it always was, so not cut.
        val old = Wire.decodeServer("""{"type":"approval","pillId":"p","fingerprint":"$fp","tool":"Bash","command":"ls","createdAt":5}""") as ServerMsg.Approval
        assertFalse(old.request.truncated)
    }

    @Test fun malformedInputNeverThrows() {
        for (bad in listOf("", "not json", "{}", """{"type":1}""", """{"type":"sessions"}""", """{"type":"welcome"}""", """{"type":"nope"}""", "[]")) {
            assertNull(bad, Wire.decodeServer(bad))
        }
    }

    @Test fun oversizeLineIsRejected() {
        assertNull(Wire.decodeServer("""{"type":"pong","pad":"${"x".repeat(Protocol.MAX_LINE_BYTES)}"}"""))
    }

    @Test fun decodesSimpleMessages() {
        assertEquals(ServerMsg.Pong, Wire.decodeServer("""{"type":"pong"}"""))
        assertEquals(ServerMsg.ApprovalResolved(fp), Wire.decodeServer("""{"type":"approvalResolved","fingerprint":"$fp"}"""))
        assertEquals(ServerMsg.Welcome(1, "PC", "windows"), Wire.decodeServer("""{"type":"welcome","v":1,"desktop":"PC","os":"windows"}"""))
    }
}
