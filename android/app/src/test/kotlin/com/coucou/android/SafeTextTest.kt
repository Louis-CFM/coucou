package com.coucou.android

import com.coucou.android.core.HomeText
import com.coucou.android.core.SafeText
import com.coucou.android.core.ToolLabels
import com.coucou.android.link.SessionInfo
import com.coucou.android.mochi.BotState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SafeTextTest {
    private val secrets = listOf("hunter2", "sk-live-4242", "ghp_ABCDEF", "s3cr3t", "AKIAIOSFODNN7", "p@ss", "/home/me", "C:\\Users", "token=", "Bearer")

    private fun assertClean(s: String) { for (x in secrets) assertFalse("'$s' leaks $x", s.contains(x)) }

    @Test fun theProgramIsTheFirstPlainWord() {
        assertEquals("npm", SafeText.program("npm test"))
        assertEquals("git", SafeText.program("  git   push --force origin main"))
        assertEquals("cargo", SafeText.program("cargo test --workspace"))
    }

    @Test fun flagsAndEnvironmentVariablesAreNeverTheProgram() {
        assertNull(SafeText.program("--token=hunter2 run"))
        assertNull(SafeText.program("-rf /"))
        assertEquals("npm", SafeText.program("API_KEY=sk-live-4242 NODE_ENV=prod npm run build"))
        assertNull(SafeText.program("API_KEY=sk-live-4242"))
        assertNull(SafeText.program("password=hunter2"))
    }

    @Test fun aPathIsReducedToItsFileNameAndAUrlIsDropped() {
        assertEquals("run.sh", SafeText.program("/home/me/secret/run.sh --go"))
        assertEquals("tool.exe", SafeText.program("C:\\Users\\me\\bin\\tool.exe /x"))
        assertNull(SafeText.program("https://user:hunter2@example.com/x"))
        assertNull(SafeText.program("ftp://admin:s3cr3t@host"))
        assertNull(SafeText.program("user:p@ss@host"))
    }

    @Test fun theNameIsCutAtTwentyCharactersAndOddCharactersGiveNothing() {
        assertEquals(20, SafeText.program("a".repeat(60))!!.length)
        assertNull(SafeText.program("\$(curl evil)"))
        assertNull(SafeText.program("echo;rm"))
        assertNull(SafeText.program(""))
        assertNull(SafeText.program(null))
    }

    @Test fun aRequestShowsALabelAndForAShellTheProgramOnly() {
        val cmds = listOf(
            "curl -H 'Authorization: Bearer ghp_ABCDEF' https://user:hunter2@example.com/x",
            "AWS_SECRET=AKIAIOSFODNN7 /home/me/bin/deploy --password s3cr3t",
            "mysql -u root -phunter2 -h db",
        )
        assertEquals("Running a command · curl", SafeText.requestLabel("Bash", cmds[0]))
        assertEquals("Running a command · deploy", SafeText.requestLabel("Bash", cmds[1]))
        assertEquals("Running a command · mysql", SafeText.requestLabel("Bash", cmds[2]))
        for (c in cmds) assertClean(SafeText.requestLabel("Bash", c))
    }

    @Test fun anotherToolNeverShowsItsArgument() {
        assertEquals("Editing files", SafeText.requestLabel("Edit", "/home/me/.ssh/config"))
        assertEquals("Editing files", SafeText.requestLabel("Write", "C:\\Users\\me\\secret.txt"))
        assertEquals("Mcp github create issue", SafeText.requestLabel("mcp__github__create_issue", "title=hunter2"))
        assertEquals("Working", SafeText.requestLabel("", "rm -rf /"))
    }

    @Test fun aStepFromTheComputerShowsNoCommandAndNoPath() {
        val steps = listOf(
            "Bash · curl -u admin:hunter2 https://x.example/api",
            "Edit · /home/me/secret/plan.md",
            "Read · C:\\Users\\me\\.aws\\credentials",
            "Bash · TOKEN=sk-live-4242 ./deploy.sh",
        )
        val shown = steps.map { ToolLabels.label(it) }
        assertEquals(listOf("Running a command · curl", "Editing files", "Reading files", "Running a command · deploy.sh"), shown)
        for (s in shown) assertClean(s)
        // Home's line for a working agent is the same label.
        assertEquals("Running a command · curl", HomeText.line(SessionInfo("p", "A", BotState.WORKING, steps[0], 0, 0, 0L)))
    }

    @Test fun anAgentsLastMessageLosesPathsUrlsAndKeyValuePairs() {
        val said = "Fixed it in /home/me/secret/app.rs, see https://user:hunter2@git.example/x and set TOKEN=sk-live-4242 then C:\\Users\\me\\a.txt done."
        val shown = SafeText.prose(said)
        assertClean(shown)
        assertTrue(shown, shown.startsWith("Fixed it in"))
        assertTrue(shown, shown.endsWith("done."))
        assertEquals("All tests pass.", SafeText.prose("All tests pass."))
        val s = SessionInfo("p", "A", BotState.FINISHED, "", 0, 0, 0L, finalLine = said)
        assertClean(HomeText.line(s)!!)
        assertNull(HomeText.line(SessionInfo("p", "A", BotState.FINISHED, "", 0, 0, 0L, finalLine = "/home/me/secret/app.rs")))
    }

    @Test fun noSurfaceThatIsSeenWithoutATapPrintsTheCommand() {
        val main = "src/main/kotlin/com/coucou/android/"
        val n = java.io.File(main + "app/Notifications.kt").readText()
        assertFalse(n.replace("SafeText.requestLabel(r.tool, r.command)", "").contains("r.command"))
        assertFalse(n.contains("setSubText(statusText"))
        for (f in listOf("ui/HomePanel.kt", "ui/SessionScreen.kt", "ui/IslandOverlay.kt", "core/IslandPlan.kt", "core/Glance.kt", "ui/UsagePanel.kt")) {
            assertFalse("$f prints a command", java.io.File(main + f).readText().contains(".command"))
        }
        // The only screen that prints it sits behind "Show exact command" (a deliberate tap).
        val sheets = java.io.File(main + "ui/Sheets.kt").readText()
        val reveal = sheets.substringAfter("if (showCommand) {")
        assertTrue(reveal.contains("r.command"))
        assertFalse(sheets.substringBefore("if (showCommand) {").contains("r.command"))
        // And the phone's own history keeps a label, not the command.
        assertTrue(java.io.File(main + "app/AppModel.kt").readText().contains("SafeText.requestLabel(request.tool, request.command)"))
    }
}
