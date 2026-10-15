package com.coucou.android.link

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProtocolDiffsTest {
    private fun sessionWith(files: String) = Wire.decodeServer(
        """{"type":"sessions","sessions":[{"pillId":"integration_claude","agent":"Claude Code","state":"working","statusText":"x","stepIndex":1,"stepCount":2,"files":$files}]}""",
    ) as ServerMsg.Sessions

    @Test fun aSessionWithoutFilesHasNone() {
        assertEquals(emptyList<FileChange>(), sessionWith("[]").sessions[0].files)
        val plain = Wire.decodeServer("""{"type":"sessions","sessions":[{"pillId":"a","agent":"x","state":"idle"}]}""") as ServerMsg.Sessions
        assertEquals(emptyList<FileChange>(), plain.sessions[0].files)
    }

    @Test fun filesAreReadAsNamesAndCounts() {
        val f = sessionWith("""[{"id":3,"name":"app.ts","added":2,"removed":1},{"id":4,"name":"n.md","added":9,"removed":0,"tooLarge":true,"isNew":true}]""").sessions[0].files
        assertEquals(FileChange(3, "app.ts", 2, 1), f[0])
        assertEquals(FileChange(4, "n.md", 9, 0, tooLarge = true, isNew = true), f[1])
    }

    @Test fun evenIfAPathIsSentOnlyTheNameIsKept() {
        val f = sessionWith("""[{"id":1,"name":"/home/me/secret/app.ts"},{"id":2,"name":"C:\\Users\\me\\notes.md"},{"id":3,"name":"dir/"}]""").sessions[0].files
        assertEquals(listOf("app.ts", "notes.md", "dir"), f.map { it.name })
        assertFalse(f.toString().contains("secret") || f.toString().contains("Users"))
    }

    @Test fun anEntryWithoutAnIdOrANameIsSkippedAndCountsCannotBeNegative() {
        val f = sessionWith("""[{"name":"a"},{"id":1},{"id":2,"name":""},{"id":3,"name":".."},{"id":-4,"name":"neg"},{"id":5,"name":"ok","added":-3,"removed":-1},"junk",7]""").sessions[0].files
        assertEquals(listOf(FileChange(5, "ok", 0, 0)), f)
    }

    @Test fun atMostTwentyFilesTheNewest() {
        val many = (0 until 30).joinToString(",", "[", "]") { """{"id":$it,"name":"f$it"}""" }
        val f = sessionWith(many).sessions[0].files
        assertEquals(20, f.size)
        assertEquals(10L, f.first().id)
        assertEquals(29L, f.last().id)
    }

    @Test fun aLongNameIsCut() {
        val f = sessionWith("""[{"id":1,"name":"${"n".repeat(300)}"}]""").sessions[0].files
        assertEquals(Protocol.MAX_FILE_NAME_CHARS, f[0].name.length)
    }

    @Test fun getDiffIsEncoded() {
        val o = JSONObject(Wire.encode(ClientMsg.GetDiff("integration_claude", 7)))
        assertEquals("getDiff", o.getString("type"))
        assertEquals("integration_claude", o.getString("pillId"))
        assertEquals(7L, o.getLong("fileId"))
    }

    private fun diff(extra: String = "", lines: String = """[["+","a"],["-","b"]]""", part: Int = 0, parts: Int = 1) = Wire.decodeServer(
        """{"type":"diff","pillId":"integration_claude","fileId":7,"name":"/x/app.ts","added":1,"removed":1,"tooLarge":false,"gone":false,"truncated":false,"part":$part,"parts":$parts,"lines":$lines$extra}""",
    )

    @Test fun aDiffPartIsRead() {
        val d = diff() as ServerMsg.Diff
        assertEquals("app.ts", d.name)
        assertEquals(listOf(DiffRow('+', "a"), DiffRow('-', "b")), d.lines)
        assertEquals(7L, d.fileId)
    }

    @Test fun anUnknownKindIsAContextLineAndLongTextIsCut() {
        val d = diff(lines = """[["x","y"],["+","${"z".repeat(900)}"],["@@","h"]]""") as ServerMsg.Diff
        assertEquals(' ', d.lines[0].kind)
        assertEquals(Protocol.MAX_DIFF_LINE_CHARS, d.lines[1].text.length)
        assertEquals(' ', d.lines[2].kind)
    }

    @Test fun aPartBeyondTheComputersLimitsIsDropped() {
        val tooMany = (0..100).joinToString(",", "[", "]") { """["+","l"]""" }
        assertNull(diff(lines = tooMany))
        assertNotNull(diff(lines = (0 until 100).joinToString(",", "[", "]") { """["+","l"]"""}))
        assertNull(diff(part = 1, parts = 1))
        assertNull(diff(part = 0, parts = 0))
        assertNull(diff(part = 0, parts = 5))
        assertNull(diff(part = -1, parts = 2))
        assertNull(Wire.decodeServer("""{"type":"diff","pillId":"a","fileId":1,"part":0,"parts":1}"""))
        assertNull(diff(lines = """[["+"]]"""))
    }

    @Test fun theHelloAsksForDiffs() {
        assertTrue(Protocol.CAP_DIFFS in Protocol.CAPABILITIES)
    }
}
