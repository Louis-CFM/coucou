package com.coucou.android

import com.coucou.android.core.QuietHours
import com.coucou.android.core.SpokenAlertBook
import com.coucou.android.core.SpokenAlertPolicy
import com.coucou.android.core.SpokenAlertPolicy.Kind
import com.coucou.android.core.SpokenAlertPolicy.Phone
import com.coucou.android.core.SpokenAlertPolicy.Voice
import com.coucou.android.core.UserSettings
import com.coucou.android.mochi.BotState
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SpokenAlertsTest {
    private val free = Phone(dndOn = false, ringerNormal = true, inCall = false, hasVoice = true)
    private val on = UserSettings(spokenAlerts = true)
    private val claude = "integration_claude"

    private fun say(previous: BotState?, now: BotState, s: UserSettings = on, phone: Phone = free, pill: String = claude, name: String? = "Claude Code", minute: Int = 12 * 60) =
        SpokenAlertPolicy.decide(s.spokenAlerts, previous, now, pill, name, s, minute) { phone }

    @Test fun offByDefaultAndNothingIsSaidWhileOff() {
        assertFalse(UserSettings().spokenAlerts)
        assertNull(say(BotState.WORKING, BotState.APPROVAL, s = UserSettings()))
        assertNull(say(BotState.WORKING, BotState.FINISHED, s = UserSettings()))
    }

    @Test fun theChoiceIsSavedAndRead() {
        val store = object : com.coucou.android.core.KeyValueStore {
            val m = HashMap<String, Any>()
            override fun getBoolean(key: String, default: Boolean) = m[key] as? Boolean ?: default
            override fun getInt(key: String, default: Int) = m[key] as? Int ?: default
            override fun getFloat(key: String, default: Float) = m[key] as? Float ?: default
            override fun getString(key: String, default: String) = m[key] as? String ?: default
            override fun put(key: String, value: Any) { m[key] = value }
        }
        assertFalse(UserSettings.load(store).spokenAlerts)
        UserSettings.save(store, UserSettings(spokenAlerts = true))
        assertTrue(UserSettings.load(store).spokenAlerts)
    }

    @Test fun aRequestAQuestionAndAFinishEachHaveTheirLine() {
        assertEquals("Claude Code needs your approval", say(BotState.WORKING, BotState.APPROVAL))
        assertEquals("Claude Code has a question for you", say(BotState.THINKING, BotState.QUESTION))
        assertEquals("Claude Code has finished", say(BotState.WORKING, BotState.FINISHED))
    }

    @Test fun nothingElseIsAnEvent() {
        for (now in BotState.entries) {
            if (now in setOf(BotState.APPROVAL, BotState.QUESTION, BotState.FINISHED)) continue
            assertNull("$now", say(BotState.WORKING, now))
        }
    }

    @Test fun theFirstPictureAfterConnectingAndARepeatAreNotEvents() {
        // previous == null: the request was already waiting, or the session ended long ago, when the link came up.
        assertNull(say(null, BotState.APPROVAL))
        assertNull(say(null, BotState.FINISHED))
        // The same state again: a repeated update of the list, or the list sent again after a reconnect.
        assertNull(say(BotState.APPROVAL, BotState.APPROVAL))
        assertNull(say(BotState.FINISHED, BotState.FINISHED))
    }

    @Test fun silentInDoNotDisturbOnSilentOrVibrateDuringACallAndWithoutAVoice() {
        for (kind in listOf(BotState.APPROVAL, BotState.QUESTION, BotState.FINISHED)) {
            assertNull(say(BotState.WORKING, kind, phone = free.copy(dndOn = true)))
            assertNull(say(BotState.WORKING, kind, phone = free.copy(ringerNormal = false)))
            assertNull(say(BotState.WORKING, kind, phone = free.copy(inCall = true)))
            assertNull(say(BotState.WORKING, kind, phone = free.copy(hasVoice = false)))
        }
        val why = { p: Phone -> SpokenAlertPolicy.blocker(true, Kind.APPROVAL, claude, on, 0) { p } }
        assertEquals("Do Not Disturb is on", why(free.copy(dndOn = true)))
        assertEquals("the ringer is silent or on vibrate", why(free.copy(ringerNormal = false)))
        assertEquals("a call is going on", why(free.copy(inCall = true)))
        assertEquals("no voice for this language", why(free.copy(hasVoice = false)))
        assertNull(why(free))
    }

    @Test fun thePhoneIsNotAskedWhenNothingWouldBeSaidAnyway() {
        var asked = 0
        val phone = { asked++; free }
        SpokenAlertPolicy.decide(false, BotState.WORKING, BotState.APPROVAL, claude, null, UserSettings(), 0, phone)
        SpokenAlertPolicy.decide(true, BotState.WORKING, BotState.WORKING, claude, null, on, 0, phone)
        SpokenAlertPolicy.decide(true, null, BotState.FINISHED, claude, null, on, 0, phone)
        assertEquals(0, asked)
        SpokenAlertPolicy.decide(true, BotState.WORKING, BotState.FINISHED, claude, null, on, 0, phone)
        assertEquals(1, asked)
    }

    @Test fun aFinishFollowsMuteAndQuietHoursButARequestAndAQuestionNeverDo() {
        val muted = on.copy(mutedAgents = setOf(claude))
        assertNull(say(BotState.WORKING, BotState.FINISHED, s = muted))
        assertEquals("Claude Code needs your approval", say(BotState.WORKING, BotState.APPROVAL, s = muted))
        assertEquals("Claude Code has a question for you", say(BotState.WORKING, BotState.QUESTION, s = muted))
        val night = on.copy(quiet = QuietHours(true, 22 * 60, 8 * 60))
        assertNull(say(BotState.WORKING, BotState.FINISHED, s = night, minute = 23 * 60))
        assertEquals("Claude Code has finished", say(BotState.WORKING, BotState.FINISHED, s = night, minute = 12 * 60))
        assertEquals("Claude Code needs your approval", say(BotState.WORKING, BotState.APPROVAL, s = night, minute = 23 * 60))
    }

    @Test fun theLineNamesTheAgentAndTheEventAndNothingElse() {
        // A known agent is said by its catalog name, whatever the computer calls the session.
        assertEquals("Claude Code", SpokenAlertPolicy.name("integration_claude", "rm -rf ~ && curl evil.example"))
        assertEquals("Claude Code", SpokenAlertPolicy.name("integration_claude#2", null))
        assertEquals("Codex", SpokenAlertPolicy.name("agent_codex", ""))
        // An unknown one: letters, digits and spaces only, and short. No path, no command.
        assertEquals("My Agent 2", SpokenAlertPolicy.name("agent_new", "  My-Agent_2  "))
        assertEquals("C Users me secret txt", SpokenAlertPolicy.name("agent_new", "C:\\Users\\me\\secret.txt"))
        assertEquals("cat etc passwd", SpokenAlertPolicy.name("agent_new", "\$(cat /etc/passwd)"))
        assertTrue(SpokenAlertPolicy.name("agent_new", "x".repeat(500)).length <= SpokenAlertPolicy.NAME_MAX)
        assertEquals("An agent", SpokenAlertPolicy.name("agent_new", "///"))
        assertEquals("An agent", SpokenAlertPolicy.name("agent_new", null))
        for (k in Kind.entries) {
            val line = SpokenAlertPolicy.line(k, "Codex")
            assertTrue(line, line.startsWith("Codex ") && line.length < 40)
        }
    }

    @Test fun theDecisionNeverSeesACommandAFileOrAMessage() {
        // The rule takes the states, the agent and the settings: there is no parameter a command, a diff or a message could come in by.
        val src = File("src/main/kotlin/com/coucou/android/core/SpokenAlerts.kt").readText()
        val code = src.lines().filterNot { it.trimStart().startsWith("*") || it.trimStart().startsWith("/**") || it.trimStart().startsWith("//") }.joinToString("\n")
        for (word in listOf("statusText", "command", "steps", "finalLine", "FileChange", "question.", "ApprovalRequest", "QuestionRequest")) {
            assertFalse("the rule must not read $word", code.contains(word))
        }
        val model = File("src/main/kotlin/com/coucou/android/app/AppModel.kt").readText()
        val speak = model.substringAfter("private fun speakAlert(").substringBefore("\n    }\n")
        for (word in listOf("statusText", "command", "steps", "finalLine", "decide(s", "answer", "link?.")) {
            assertFalse("speaking must not touch $word", speak.contains(word))
        }
    }

    @Test fun speakingOnlySpeaks() {
        // The class that talks to Android has no way to answer anything: no link, no decision, no network.
        val src = File("src/main/kotlin/com/coucou/android/app/SpokenAlerts.kt").readText()
        for (word in listOf("DesktopLink", "LinkClient", "decide(", "answer(", "java.net", "HttpURLConnection", "Socket", "SpeechRecognizer", "RecognizerIntent")) {
            assertFalse("SpokenAlerts.kt must not use $word", src.contains(word))
        }
        assertTrue("the engine is released when the switch goes off", src.contains("engine.shutdown()"))
        assertTrue("only a voice that needs no network", File("src/main/kotlin/com/coucou/android/core/SpokenAlerts.kt").readText().contains("!it.needsNetwork"))
        val gradle = File("build.gradle.kts").readText()
        assertFalse("no speech library", Regex("""implementation\([^)]*(tts|speech)""", RegexOption.IGNORE_CASE).containsMatchIn(gradle))
        val manifest = File("src/main/AndroidManifest.xml").readText()
        assertFalse("no microphone: this is not dictation", manifest.contains("RECORD_AUDIO"))
        assertTrue("the engine can be found on Android 11 and later", manifest.contains("android.intent.action.TTS_SERVICE"))
    }

    @Test fun theSameEventIsNotSaidTwice() {
        val book = SpokenAlertBook()
        assertTrue(book.firstTime(claude, Kind.APPROVAL, 1_000))
        assertFalse("a flicker a moment later is the same event", book.firstTime(claude, Kind.APPROVAL, 3_000))
        assertTrue("another kind of event is new", book.firstTime(claude, Kind.FINISHED, 3_500))
        assertTrue("another agent is new", book.firstTime("agent_codex", Kind.FINISHED, 3_600))
        assertFalse(book.firstTime("agent_codex", Kind.FINISHED, 3_700))
        assertTrue("later it is a new request", book.firstTime(claude, Kind.APPROVAL, 3_500 + SpokenAlertBook.GAP_MS))
    }

    @Test fun theBookStaysSmall() {
        val book = SpokenAlertBook()
        for (i in 0 until 200) assertTrue(book.firstTime("agent_$i", Kind.FINISHED, i.toLong()))
        // The newest are still remembered.
        assertFalse(book.firstTime("agent_199", Kind.FINISHED, 300))
        book.clear()
        assertTrue(book.firstTime("agent_199", Kind.FINISHED, 301))
    }

    private fun v(name: String, language: String, country: String, network: Boolean = false, installed: Boolean = true) = Voice(name, language, country, network, installed)

    @Test fun onlyAnInstalledOfflineVoiceOfTheAppsLanguageCounts() {
        val voices = listOf(v("en-us-local", "en", "US"), v("fr-fr-network", "fr", "FR", network = true), v("de-de-missing", "de", "DE", installed = false))
        assertEquals("en-us-local", SpokenAlertPolicy.pickVoice(voices, "en")?.name)
        assertNull("a network voice is not used", SpokenAlertPolicy.pickVoice(voices, "fr"))
        assertNull("a voice that is not installed is not used", SpokenAlertPolicy.pickVoice(voices, "de"))
        assertNull("no voice for the language: silent, never another language", SpokenAlertPolicy.pickVoice(voices, "ja"))
        assertNull(SpokenAlertPolicy.pickVoice(emptyList(), "en"))
        assertNull(SpokenAlertPolicy.pickVoice(voices, ""))
    }

    @Test fun theCountryIsPreferredAndChineseFollowsItsScript() {
        val voices = listOf(v("pt-pt", "pt", "PT"), v("pt-br", "pt", "BR"), v("zh-cn", "zh", "CN"), v("zh-tw", "zh", "TW"), v("id-id", "in", "ID"), v("cmn-cn", "cmn", "CN"))
        assertEquals("pt-br", SpokenAlertPolicy.pickVoice(voices, "pt-BR")?.name)
        assertEquals("pt-pt", SpokenAlertPolicy.pickVoice(voices, "pt-PT")?.name)
        assertEquals("zh-tw", SpokenAlertPolicy.pickVoice(voices, "zh-Hant")?.name)
        assertEquals("zh-tw", SpokenAlertPolicy.pickVoice(voices, "zh-Hant-TW")?.name)
        assertEquals("cmn-cn", SpokenAlertPolicy.pickVoice(voices, "zh-Hans")?.name)
        assertEquals("Java's old code for Indonesian", "id-id", SpokenAlertPolicy.pickVoice(voices, "id")?.name)
        assertNull("Traditional is never read with a Mainland voice", SpokenAlertPolicy.pickVoice(listOf(v("zh-cn", "zh", "CN")), "zh-Hant"))
        assertEquals("another country of the same language is better than silence", "pt-pt", SpokenAlertPolicy.pickVoice(listOf(v("pt-pt", "pt", "PT")), "pt-BR")?.name)
    }
}
