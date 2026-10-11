package com.coucou.android

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Source-level guards for the session detail screen (Compose cannot be rendered in a JVM test). */
class SessionScreenTest {
    private fun src(name: String) = File("src/main/kotlin/com/coucou/android/$name").readText()
    private val strings get() = File("src/main/res/values/strings.xml").readText()

    @Test fun theCardOpensTheDetailsOnlyWhenTheyExist() {
        val main = src("MainActivity.kt")
        assertTrue(main.contains("onDetails = if (focus != null && HomePanel.hasDetails(focus))"))
        assertTrue(main.contains("Screen.SESSION -> SessionScreen("))
        val hero = src("ui/HomePanel.kt")
        assertTrue("the Details pill exists only when there is something to open", hero.contains("if (onDetails != null)") && hero.contains("R.string.session_details), onDetails"))
    }

    @Test fun stepsAreShownInPlainWordsAndTheProjectIsOnlyAName() {
        val ui = src("ui/SessionScreen.kt")
        assertTrue(ui.contains("ToolLabels.label(step)"))
        assertTrue(ui.contains("R.string.session_project"))
        // the screen never draws a path or the raw step text
        assertFalse(ui.contains("Environment") || ui.contains("filesDir") || ui.contains("File("))
    }

    @Test fun withoutTheSwitchTheScreenSaysWhereToTurnItOn() {
        assertTrue(src("ui/SessionScreen.kt").contains("R.string.session_hint"))
        assertTrue(strings.contains("Show session details on the phone"))
        assertTrue(src("app/AppModel.kt").contains("detailsOffered = Protocol.CAP_DETAILS in caps"))
    }

}
