package com.coucou.android

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Guards for how the island over other apps is drawn (the window cannot be rendered in a JVM test, so these read the source). */
class IslandOverlayTest {
    private val src = File("src/main/kotlin/com/coucou/android/ui/IslandOverlay.kt").readText()

    @Test fun theRequestCardNamesTheActionAndNeverShowsTheCommand() {
        val card = src.substringAfter("private fun RequestCard").substringBefore("A window outside any activity")
        assertTrue(card.contains("R.string.approval_wants"))
        assertFalse(card.contains("Monospace") || card.contains(".command") || card.contains("s.text,"))
        assertTrue("Allow keeps its lock note", card.contains("R.string.approval_hint"))
    }

    @Test fun everyTapStillGoesThroughTheEarlyTapGuard() {
        for (what in listOf("tap(\"Deny\")", "tap(\"Allow\")", "tap(\"the request header\")", "tap(\"the result card\")", "tap(\"the working strip\")")) {
            assertTrue(what, src.contains(what))
        }
    }
}
