package com.coucou.android

import com.coucou.android.core.Decision
import com.coucou.android.core.HistoryExport
import java.io.File
import java.time.ZoneId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HistoryExportTest {
    private val zone = ZoneId.of("UTC")
    private val at = 1_792_000_000_000L // 2026-10-14 ... UTC
    private val list = listOf(
        Decision("Claude Code", "Bash", "rm -rf secret-folder", true, at),
        Decision("Codex", "Edit", "src/private.kt", false, at - 3_600_000),
        Decision("Claude Code", "Read", "notes.txt", true, at - 7_200_000),
    )

    @Test fun aBlankSearchKeepsEverything() {
        assertEquals(list, HistoryExport.filter(list, ""))
        assertEquals(list, HistoryExport.filter(list, "   "))
    }

    @Test fun everyWordMustMatchTheWordingOrTheAgentAnyCase() {
        assertEquals(listOf(list[1]), HistoryExport.filter(list, "codex"))
        assertEquals(listOf(list[1]), HistoryExport.filter(list, "DENIED"))
        assertEquals(listOf(list[0], list[2]), HistoryExport.filter(list, "claude allowed"))
        assertEquals(emptyList<Decision>(), HistoryExport.filter(list, "claude denied"))
    }

    @Test fun theCommandIsNeverSearched() {
        assertEquals(emptyList<Decision>(), HistoryExport.filter(list, "secret-folder"))
        assertEquals(emptyList<Decision>(), HistoryExport.filter(list, "private.kt"))
    }

    @Test fun aHugeSearchIsCut() {
        assertEquals(emptyList<Decision>(), HistoryExport.filter(list, "x".repeat(100_000)))
    }

    @Test fun theTextHasTheHeaderThenOneLinePerDecisionAndNoCommand() {
        val t = HistoryExport.text(list, "Coucou · recent decisions", zone)
        val lines = t.lines()
        assertEquals("Coucou · recent decisions", lines[0])
        assertEquals("", lines[1])
        assertEquals(5, lines.size)
        assertTrue(lines[2].matches(Regex("""\d{4}-\d{2}-\d{2} \d{2}:\d{2}  You allowed Claude Code to .+""")))
        assertTrue(lines[3].contains("You denied Codex to"))
        for (secret in listOf("secret-folder", "rm -rf", "private.kt", "notes.txt")) assertFalse(secret, t.contains(secret))
    }

    @Test fun anEmptyListIsJustTheHeader() {
        assertEquals(listOf("Header", ""), HistoryExport.text(emptyList(), "Header", zone).lines())
    }

    @Test fun exportGoesThroughTheShareSheetAndNothingElse() {
        val ui = File("src/main/kotlin/com/coucou/android/ui/SettingsScreens.kt").readText()
        val block = ui.substringAfter("fun HistoryScreen").substringBefore("private fun RelayCard")
        assertTrue(block.contains("Intent.createChooser("))
        assertTrue(block.contains("Intent.ACTION_SEND"))
        for (word in listOf("http", "Socket", "link.", "model.send")) assertFalse(word, block.contains(word))
    }
}
