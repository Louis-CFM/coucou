package com.coucou.android.link

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProtocolLaunchTest {
    @Test fun theAppAsksForLaunch() {
        assertTrue(Protocol.CAP_LAUNCH in Protocol.CAPABILITIES)
        val hello = JSONObject(Wire.encode(ClientMsg.Hello(1, "T".repeat(20), "Phone", Protocol.CAPABILITIES)))
        assertTrue(hello.getJSONArray("caps").toString().contains("\"launch\""))
    }

    @Test fun theRequestCarriesAnIdAProjectIdAndTheWordsAndNothingElse() {
        val o = JSONObject(Wire.encode(ClientMsg.Launch("a1b2", "3f9a00112233aabb", "fix the \"login\" bug; rm -rf /")))
        assertEquals(setOf("type", "id", "project", "prompt"), o.keySet())
        assertEquals("launch", o.getString("type"))
        assertEquals("a1b2", o.getString("id"))
        assertEquals("3f9a00112233aabb", o.getString("project"))
        assertEquals("fix the \"login\" bug; rm -rf /", o.getString("prompt"))
    }

    @Test fun theProjectsAreFolderNamesWithTheComputersIds() {
        val m = Wire.decodeServer("""{"type":"projects","projects":[{"id":"3f9a00112233aabb","name":"coucou"},{"id":"00ff00ff00ff00ff","name":"my site"}]}""")
        assertEquals(ServerMsg.Projects(listOf(LaunchProject("3f9a00112233aabb", "coucou"), LaunchProject("00ff00ff00ff00ff", "my site"))), m)
        assertEquals(ServerMsg.Projects(emptyList()), Wire.decodeServer("""{"type":"projects","projects":[]}"""))
    }

    @Test fun aPathIsCutToItsFolderNameAndJunkIsDropped() {
        val line = """{"type":"projects","projects":[
            {"id":"aa","name":"/home/someone/private/proj"},
            {"id":"bb","name":"C:\\Users\\someone\\site"},
            {"id":"has space","name":"x"},
            {"id":"aa","name":"twice"},
            {"id":"cc","name":""},
            {"id":"dd"},
            "nonsense",
            {"id":"ee","name":"ok"}]}""".replace("\n", "")
        val m = Wire.decodeServer(line) as ServerMsg.Projects
        assertEquals(listOf(LaunchProject("aa", "proj"), LaunchProject("bb", "site"), LaunchProject("ee", "ok")), m.projects)
        assertTrue(m.projects.none { it.name.contains('/') || it.name.contains('\\') || it.name.contains("someone") })
    }

    @Test fun atMostTenProjects() {
        val many = (0 until 40).joinToString(",") { """{"id":"p$it","name":"n$it"}""" }
        val m = Wire.decodeServer("""{"type":"projects","projects":[$many]}""") as ServerMsg.Projects
        assertEquals(Protocol.MAX_PROJECTS, m.projects.size)
        assertEquals("n0", m.projects.first().name)
    }

    @Test fun theAnswerIsStartedOrRefusedWithAWord() {
        assertEquals(ServerMsg.LaunchResult("a1", true, ""), Wire.decodeServer("""{"type":"launchResult","id":"a1","ok":true}"""))
        assertEquals(ServerMsg.LaunchResult("a1", false, "rate"), Wire.decodeServer("""{"type":"launchResult","id":"a1","ok":false,"reason":"rate"}"""))
        // Malformed: no id, a bad id, no verdict. Dropped, never guessed.
        assertNull(Wire.decodeServer("""{"type":"launchResult","ok":true}"""))
        assertNull(Wire.decodeServer("""{"type":"launchResult","id":"has space","ok":true}"""))
        assertNull(Wire.decodeServer("""{"type":"launchResult","id":"a1"}"""))
        val long = Wire.decodeServer("""{"type":"launchResult","id":"a1","ok":false,"reason":"${"x".repeat(500)}"}""") as ServerMsg.LaunchResult
        assertTrue(long.reason.length <= 32)
    }
}
