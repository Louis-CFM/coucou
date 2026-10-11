package com.coucou.android

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guards for the approval and question sheets (Compose cannot be rendered in a JVM test, so these read the
 * sources). The point of the redesign here: no raw command on screen unless asked for, and nothing about Allow gets weaker.
 */
class SheetsTest {
    private fun src(name: String) = File("src/main/kotlin/com/coucou/android/$name").readText()
    private val sheets get() = src("ui/Sheets.kt")
    private val main get() = src("MainActivity.kt")

    @Test fun theCommandIsOnlyDrawnAfterShowExactCommand() {
        assertEquals("the command is drawn in exactly one place", 1, Regex("""r\.command""").findAll(sheets).count())
        val before = sheets.substringBefore("r.command")
        assertTrue(before.substringAfterLast("if (showCommand)").length < 600)
        assertTrue(before.contains("if (showCommand)"))
    }

    @Test fun aCutCommandIsSaidClearlyAndAllowIsOnlyOfferedWhenTheWholeCommandIsHere() {
        assertTrue(sheets.contains("R.string.approval_too_long"))
        // Allow is drawn only under the check, and the notice is not behind a tap.
        assertTrue(sheets.substringAfter("val canAllow").substringBefore("PillKind.PRIMARY").contains("if (canAllow)"))
        assertFalse(sheets.substringAfter("approval_too_long").substringBefore("canAllow").contains("showCommand"))
        // The same rule at every door: the sheet's callback, the model, the notification and the island.
        assertTrue(main.contains("ApprovalSheetPlan.canAllowHere(r)"))
        assertTrue(src("app/AppModel.kt").substringAfter("fun decide(fingerprint").substringBefore("link?.decide").contains("canAllowHere(request)"))
        assertTrue(src("app/Notifications.kt").contains("if (ApprovalSheetPlan.canAllowHere(r)) addAction"))
        assertTrue(src("ui/IslandOverlay.kt").contains("if (s.canAllow)"))
    }

    @Test fun theCommandIsNeverCutByALineLimit() {
        assertFalse(sheets.contains("maxLines = ApprovalSheetPlan.MAX"))
        assertTrue(sheets.contains("verticalScroll(rememberScrollState())"))
    }

    @Test fun homeNoLongerDrawsARawCommand() {
        // the only place left is the lock prompt, which must keep repeating the exact command
        assertEquals(1, Regex("""r\.command""").findAll(main).count())
        assertTrue(main.contains("\"${'$'}{r.tool}: ${'$'}{r.command}\""))
        assertFalse(main.contains("fun ApprovalCard"))
        assertFalse(src("ui/HomePanel.kt").contains(".command"))
    }

    @Test fun theSheetSaysTheKindOfActionAndNotTheTool() {
        assertTrue(sheets.contains("ApprovalSheetPlan.action(r.tool)"))
        assertTrue(sheets.contains("R.string.approval_wants"))
    }

    @Test fun allowStillGoesThroughTheLockAndDenyNeedsNone() {
        assertFalse("the sheet never allows by itself", Regex("""allow\s*=\s*true""").containsMatchIn(sheets))
        assertTrue(sheets.contains("onAllow(r)"))
        assertTrue(main.contains("onAllow = ::approve"))
        assertTrue(main.contains("BiometricGate.confirm("))
        assertTrue(sheets.contains("model.decide(r.fingerprint, allow = false)"))
    }

    @Test fun bothButtonsIgnoreTapsDuringTheFirstMoments() {
        assertTrue(sheets.contains("delay(ApprovalSheetPlan.GUARD_MS)"))
        assertEquals(3, Regex("""enabled = armed""").findAll(sheets).count())
    }

    @Test fun theSheetCanBeClosedAndNeverCatchesTapsMeantForTheScrim() {
        assertTrue(sheets.contains("BackHandler(onBack = onDismiss)"))
        assertTrue(sheets.contains("detectTapGestures { }"))
        assertTrue(main.contains("closedApproval = pending.fingerprint"))
        assertTrue("Review request reopens it", main.contains("onReview = { closedApproval = null }"))
    }

    @Test fun aQuestionIsAnsweredOnlyAfterTheScreenLock() {
        assertTrue(main.contains("focus.state == BotState.QUESTION"))
        // The sheet never talks to the link itself: it hands the picks to the activity, which asks for the lock first.
        assertFalse(sheets.contains("model.answerQuestion"))
        val send = main.substringAfter("private fun sendAnswer").substringBefore("/** Allow:")
        assertTrue(send.indexOf("BiometricGate.confirm") in 0 until send.indexOf("model.answerQuestion"))
        assertTrue(send.contains("if (confirming) return"))
    }

    @Test fun thePicksAreNeverLoggedOrStored() {
        val send = main.substringAfter("private fun sendAnswer").substringBefore("/** Allow:")
        assertFalse(send.contains("Log."))
        val flow = src("core/QuestionFlow.kt")
        assertFalse(flow.contains("Log."))
        assertFalse(sheets.substringAfter("fun QuestionSheet").contains("rememberSaveable"))
    }

    @Test fun theAnswerButtonHasTheSameTapGuardAsAllow() {
        val q = sheets.substringAfter("fun QuestionSheet")
        assertTrue(q.contains("ApprovalSheetPlan.GUARD_MS"))
        assertTrue(q.contains("enabled = armed && QuestionFlow.complete"))
    }
    // ── the file-change sheet ──────────────────────────────────────────────────────

    private val diffSheet get() = src("ui/DiffSheet.kt")

    @Test fun theLinesOfAFileAreNeverLoggedStoredOrKeptAcrossRecreation() {
        assertFalse(diffSheet.contains("Log."))
        assertFalse(diffSheet.contains("rememberSaveable"))
        val model = src("app/AppModel.kt")
        val diffPart = model.substringAfter("A file's change (cap `diffs`)").substringBefore("override fun onApprovalResolved")
        assertFalse(diffPart.contains("Log."))
        assertFalse(diffPart.contains("kv.put") || diffPart.contains("store."))
        assertTrue("closing the sheet forgets the lines", diffPart.contains("fun closeDiff()") && diffPart.contains("DiffState.Idle"))
    }

    @Test fun anAddedOrRemovedLineIsMarkedAndNotOnlyColoured() {
        assertTrue(diffSheet.contains("'+' -> \"+\"") && diffSheet.contains("'-' -> \"−\""))
    }

    @Test fun unlinkingTheComputerClosesTheSheet() {
        val model = src("app/AppModel.kt")
        assertTrue(model.substringAfter("private fun stopLink()").take(120).contains("closeDiff()"))
    }

    @Test fun theSheetSaysWhenItCouldNotLoadOrWasCutOrIsTooLarge() {
        for (s in listOf("file_failed", "file_gone", "file_too_large", "file_truncated", "file_loading")) assertTrue(s, diffSheet.contains("R.string.$s"))
    }
}
