package com.coucou.android

import com.coucou.android.core.ChatReasons
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Source-level guards for the Chat screen (Compose cannot be rendered in a JVM test). */
class ChatScreenTest {
    private fun src(name: String) = File("src/main/kotlin/com/coucou/android/$name").readText()
    private val strings get() = File("src/main/res/values/strings.xml").readText()

    @Test fun everyReasonCodeHasAnEnglishSentence() {
        for (code in ChatReasons.KNOWN) assertTrue("chat_err_$code", strings.contains("name=\"chat_err_$code\""))
        assertEquals("internal", ChatReasons.key("something-new"))
        assertEquals("internal", ChatReasons.key(null))
        assertEquals("rate", ChatReasons.key("rate"))
    }

    @Test fun theScreenMapsEveryKnownReasonToItsSentence() {
        val ui = src("ui/ChatScreen.kt")
        for (code in ChatReasons.KNOWN.filter { it != "internal" }) assertTrue("reason $code", ui.contains("\"$code\" -> R.string.chat_err_$code"))
    }

    @Test fun theKeyNoteIsOnTheScreenAndNoKeyIsEverHandledHere() {
        val ui = src("ui/ChatScreen.kt")
        assertTrue(ui.contains("R.string.chat_note"))
        assertTrue(strings.contains("Uses your computer's API key") || strings.contains("Uses your computer\\'s API key"))
        // the phone has no key, address or provider call of its own
        for (word in listOf("api-key", "apiKey", "Authorization", "https://")) assertFalse(word, ui.contains(word))
    }

    @Test fun clearAsksFirstAndTellsTheComputerToForget() {
        val ui = src("ui/ChatScreen.kt")
        assertTrue(ui.contains("AlertDialog"))
        assertTrue(ui.contains("model.chatClear()"))
        assertTrue(src("app/AppModel.kt").contains("link?.chatReset()"))
    }

    @Test fun theBoxCannotSendWhenUnavailableEmptyOrTooLong() {
        val ui = src("ui/ChatScreen.kt")
        assertTrue(ui.contains("enabled = model.chatAvailable && length in 1..limit"))
        assertTrue(ui.contains("enabled = model.chatAvailable"))
    }

}
