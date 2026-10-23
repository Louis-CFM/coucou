package com.coucou.android

import com.coucou.android.core.ChatTabState
import com.coucou.android.core.ShareDraft
import com.coucou.android.core.ShareDraft.Outcome
import com.coucou.android.link.Protocol
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ShareDraftTest {
    private var now = 1_000L
    private val draft = ShareDraft { now }
    private val d get() = draft

    @Test fun sharedTextBecomesADraftOnce() {
        draft.offer("Explain this stack trace")
        assertTrue(draft.pending())
        assertEquals("Explain this stack trace", draft.take())
        assertNull("only once", draft.take())
        assertFalse(draft.pending())
    }

    @Test fun aStaleDraftIsDropped() {
        draft.offer("hello")
        now += ShareDraft.TTL_MS + 1
        assertNull(draft.take())
    }

    @Test fun theLastShareWins() {
        draft.offer("one")
        draft.offer("two")
        assertEquals("two", draft.take())
    }

    @Test fun blankOrMissingTextKeepsNothing() {
        draft.offer("   \n\t ")
        assertNull(draft.take())
        draft.offer(null)
        assertNull(draft.take())
        assertNull(ShareDraft.clean(""))
        assertNull(ShareDraft.clean("\u0000\u0007\u001B"))
    }

    @Test fun controlCharactersAndDirectionTricksAreDropped() {
        assertEquals("ab", ShareDraft.clean("a\u0000b"))
        assertEquals("abc", ShareDraft.clean("a\u001B[31mb‮c".replace("[31m", "")))
        assertEquals("ab", ShareDraft.clean("a‮b"))
        assertEquals("ab", ShareDraft.clean("a​b"))
        // Tabs and line breaks stay; Windows and old Mac line ends become one \n.
        assertEquals("a\tb\nc\nd\ne", ShareDraft.clean("a\tb\r\nc\rd\ne"))
    }

    @Test fun theTextIsTrimmedAndCutToTheChatLimit() {
        assertEquals("hi", ShareDraft.clean("  hi \n"))
        val long = "x".repeat(Protocol.CHAT_MAX_TEXT + 500)
        assertEquals(Protocol.CHAT_MAX_TEXT, ShareDraft.clean(long)!!.length)
        // A huge share is cut before anything else touches it.
        assertEquals(Protocol.CHAT_MAX_TEXT, ShareDraft.clean("y".repeat(5_000_000))!!.length)
    }

    @Test fun markupIsKeptAsPlainText() {
        // Nothing is interpreted: a script tag or a link is only characters in a box the user reads.
        assertEquals("<b>hi</b> https://example.com/?a=1&b=2", ShareDraft.clean("<b>hi</b> https://example.com/?a=1&b=2"))
    }

    @Test fun whatToDoForEachStateOfTheChat() {
        assertEquals(Outcome.NOTHING_TO_SHARE, ShareDraft.decide(false, ChatTabState.READY))
        assertEquals(Outcome.NOT_PAIRED, ShareDraft.decide(true, ChatTabState.NOT_PAIRED))
        assertEquals(Outcome.KEEP_AND_OPEN_CHAT, ShareDraft.decide(true, ChatTabState.NOT_CONNECTED))
        assertEquals(Outcome.CHAT_UNAVAILABLE, ShareDraft.decide(true, ChatTabState.CHAT_OFF))
        assertEquals(Outcome.CHAT_UNAVAILABLE, ShareDraft.decide(true, ChatTabState.NO_MODELS))
        assertEquals(Outcome.KEEP_AND_OPEN_CHAT, ShareDraft.decide(true, ChatTabState.READY))
    }

    @Test fun aDraftGoesAfterWhatIsAlreadyInTheBox() {
        assertEquals("draft", ShareDraft.into("", "draft"))
        assertEquals("draft", ShareDraft.into("  ", "draft"))
        assertEquals("typed\ndraft", ShareDraft.into("typed ", "draft"))
        assertEquals(Protocol.CHAT_MAX_TEXT, ShareDraft.into("a".repeat(Protocol.CHAT_MAX_TEXT), "more").length)
    }

    // ── The share target (source guards: Android classes only compile in CI) ──────────────────────

    private val main = "src/main/kotlin/com/coucou/android/"
    private val activity = File(main + "app/ShareActivity.kt").readText()
    private val manifest = File("src/main/AndroidManifest.xml").readText()

    @Test fun theShareTargetTakesPlainTextOnly() {
        val block = manifest.substringAfter("""android:name=".app.ShareActivity"""").substringBefore("</activity>")
        assertTrue(block.contains("""android:exported="true""""))
        assertEquals(listOf("android.intent.action.SEND"), Regex("""<action android:name="([^"]+)"""").findAll(block).map { it.groupValues[1] }.toList())
        assertEquals(listOf("text/plain"), Regex("""android:mimeType="([^"]+)"""").findAll(block).map { it.groupValues[1] }.toList())
        assertFalse(block.contains("SEND_MULTIPLE"))
        assertFalse(manifest.contains("EXTRA_STREAM") || activity.contains("EXTRA_STREAM") || activity.contains("ClipData") || activity.contains("getParcelable"))
    }

    @Test fun theShareTargetNeverSendsAndNeverTrustsTheExtra() {
        assertTrue(activity.contains("runCatching { shared.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString() }"))
        assertTrue(activity.contains("ShareDraft.clean("))
        assertTrue(activity.contains("model.offerShare(clean)"))
        for (word in listOf("chatSend", "sendBroadcast", "approve", "unpair", "Log.", "launch.request")) assertFalse(word, activity.contains(word))
        // The text is not logged, shown in a notification or put on the intent it opens the app with.
        assertFalse(activity.contains("putExtra"))
        assertFalse(activity.contains("Notification"))
    }

    @Test fun theMainScreenOpensOnChatWhileADraftWaits() {
        val src = File(main + "MainActivity.kt").readText()
        assertTrue(src.contains("if (model.shareDraft.pending()) screen = Screen.CHAT"))
        // It never reads the share from the intent it is started with.
        assertFalse(src.contains("EXTRA_TEXT"))
        d.offer("hi")
        assertTrue(d.pending())
        now += ShareDraft.TTL_MS + 1
        assertFalse("a stale draft does not pull the app to Chat", d.pending())
    }

    @Test fun theChatBoxReceivesTheDraftAndTheUserSends() {
        val chat = File(main + "ui/ChatScreen.kt").readText()
        assertTrue(chat.contains("model.shareDraft.take()"))
        assertTrue(chat.contains("text = ShareDraft.into(text, it)"))
        // Putting the draft in the box is all it does here; sending stays behind the send button.
        assertEquals(1, Regex("""model\.chatSend\(""").findAll(chat).count())
        assertFalse(File(main + "app/AppModel.kt").readText().substringAfter("fun offerShare").substringBefore("}").contains("chatSend"))
    }

    @Test fun everyLanguageTranslatesTheShareTexts() {
        for (f in File("../i18n/translations").listFiles()!!.filter { it.extension == "json" }) {
            for (k in listOf("share_label", "share_not_paired", "share_chat_off")) assertTrue("${f.name} lacks $k", f.readText().contains("\"$k\""))
        }
    }
}
