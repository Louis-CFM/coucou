package com.coucou.android

import com.coucou.android.core.BarFit
import com.coucou.android.core.ChatTab
import com.coucou.android.core.ChatTabState
import com.coucou.android.core.Screen
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatTabTest {
    private fun s(paired: Boolean = true, connected: Boolean = true, offered: Boolean = true, models: Int = 2) =
        ChatTab.state(paired, connected, offered, models)

    @Test fun nothingPairedComesFirst() {
        assertEquals(ChatTabState.NOT_PAIRED, s(paired = false, connected = false, offered = false, models = 0))
        assertEquals(ChatTabState.NOT_PAIRED, s(paired = false, connected = true, offered = true, models = 3))
    }

    @Test fun pairedButNotConnectedIsNotConnectedWhateverWasOfferedBefore() {
        assertEquals(ChatTabState.NOT_CONNECTED, s(connected = false))
        assertEquals(ChatTabState.NOT_CONNECTED, s(connected = false, offered = false, models = 0))
    }

    @Test fun connectedWithoutTheChatCapabilityIsChatOff() {
        assertEquals(ChatTabState.CHAT_OFF, s(offered = false, models = 0))
        assertEquals("models without the capability still mean chat is off", ChatTabState.CHAT_OFF, s(offered = false, models = 2))
    }

    @Test fun offeredWithNoModelAllowedIsNoModels() {
        assertEquals(ChatTabState.NO_MODELS, s(models = 0))
        assertEquals(ChatTabState.NO_MODELS, s(models = -1))
    }

    @Test fun connectedOfferedWithAModelIsReady() {
        assertEquals(ChatTabState.READY, s())
        assertEquals(ChatTabState.READY, s(models = 1))
    }

    @Test fun everyStateButReadyHasAWayOutOrAHint() {
        assertEquals(Screen.HOME, ChatTab.action(ChatTabState.NOT_PAIRED))
        assertEquals(Screen.SETTINGS, ChatTab.action(ChatTabState.NOT_CONNECTED))
        assertNull(ChatTab.action(ChatTabState.CHAT_OFF))
        assertNull(ChatTab.action(ChatTabState.NO_MODELS))
        assertNull(ChatTab.action(ChatTabState.READY))
    }

    @Test fun allFiveStatesAreReachable() {
        val seen = setOf(s(paired = false), s(connected = false), s(offered = false), s(models = 0), s())
        assertEquals(ChatTabState.entries.toSet(), seen)
    }
}

class BarFitTest {
    private val labels = listOf("Home", "Chat", "Settings")

    @Test fun threeLabelsFitOnTheAverageAndOnTheNarrowestPhoneAtLargeFonts() {
        for (width in listOf(360, 392, 411, 432)) for (scale in listOf(1.0, 1.15, 1.3)) {
            assertTrue("width $width dp, font scale $scale", BarFit.fits(width, labels, scale))
        }
    }

    @Test fun theLongestLabelIsTheOneThatDecidesAndStillFitsAt360DpAtOnePointThree() {
        val w = BarFit.itemWidthDp(360, 3)
        assertTrue(BarFit.labelWidthDp("Settings", 1.3) <= w)
        assertTrue("room to spare at 1.3x", w - BarFit.labelWidthDp("Settings", 1.3) > 10)
    }

    @Test fun theCheckCanFailSoItMeansSomething() {
        assertFalse(BarFit.fits(360, labels, 3.0))
        assertFalse(BarFit.fits(200, labels, 1.0))
    }

    @Test fun moreTabsWouldNotFitAtLargeFonts() {
        assertFalse(BarFit.fits(360, labels + listOf("History", "Gallery"), 1.3))
    }
}

/** Guards for the Chat tab's screens and the bar (Compose cannot be rendered in a JVM test, so these read the sources). */
class ChatTabSourceTest {
    private fun src(name: String) = File("src/main/kotlin/com/coucou/android/$name").readText()
    private val chat get() = src("ui/ChatScreen.kt")
    private val bar get() = src("ui/BottomBar.kt")
    private val strings get() = File("src/main/res/values/strings.xml").readText()

    @Test fun theBarKeepsEveryLabelOnOneLineAndGrowsWithTheFont() {
        assertTrue(bar.contains("maxLines = 1, softWrap = false"))
        assertTrue(bar.contains("height(IntrinsicSize.Min).heightIn(min = 64.dp)"))
        assertTrue(bar.contains("BarFit.ITEM_SIDE_PADDING_DP"))
        assertTrue(Regex("""BAR_SIDE_MARGIN_DP\s*=\s*24""").containsMatchIn(src("core/ChatTab.kt")) && bar.contains("padding(horizontal = 24.dp)"))
    }

    @Test fun theChatScreenShowsAnEmptyStateWhenThereIsNothingToChatWithOrRead() {
        assertTrue(chat.contains("if (tabState != ChatTabState.READY && messages.isEmpty())"))
        assertTrue(chat.contains("ChatEmpty(tabState, onHome, onSettings)"))
        assertTrue("a sleeping Mochi", chat.contains("BotState.SLEEPING"))
    }

    @Test fun anExistingConversationStaysReadableWithTheReasonAboveIt() {
        assertTrue(chat.contains("chatStateTitle(tabState)") && chat.contains("chatStateBody(tabState)"))
        assertTrue("it cannot be sent to while unavailable", chat.contains("enabled = model.chatAvailable"))
    }

    @Test fun theWordsAreTheRequestedOnesAndNoRawErrorOrSecretIsInThem() {
        assertTrue(strings.contains("Not connected"))
        assertTrue(strings.contains("Chat is off on your computer"))
        assertTrue(strings.contains("Your computer has no model allowed for the phone yet"))
        assertTrue(strings.contains("On your computer open Coucou &gt; Settings &gt; Android phone, turn on"))
        assertTrue(strings.contains("Let the phone chat with my AI providers"))
        assertTrue(strings.contains("tick a model"))
        val body = Regex("""<string name="chat_(off|nomodel)[a-z_]*">([^<]*)</string>""").findAll(strings).map { it.groupValues[2].lowercase() }.toList()
        for (b in body) for (bad in listOf("token", "key=", "exception", "error:", "http", "sha")) assertFalse("'$b' mentions $bad", b.contains(bad))
    }

    @Test fun theModelStatePicksTheScreen() {
        assertTrue(src("app/AppModel.kt").contains("val chatTabState: ChatTabState get() = ChatTab.state("))
    }

    @Test fun homeNoLongerHasAChatEntryAndThereIsNoUnreadDotToKeep() {
        val main = src("MainActivity.kt")
        assertFalse(main.contains("AskBar") || main.contains("ChatEntry"))
        assertFalse(File("src/main").walkTopDown().filter { it.isFile && it.extension == "kt" }.any { Regex("""\bunread\b""", RegexOption.IGNORE_CASE).containsMatchIn(it.readText()) })
    }
}
