package com.coucou.android

import com.coucou.android.core.WidgetData
import com.coucou.android.core.WidgetSample
import com.coucou.android.core.WidgetSpoken
import com.coucou.android.mochi.BotState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WidgetSpokenTest {
    private fun sample(s: WidgetSample) = WidgetData.sample(s, 1_000_000L)

    @Test fun everyMoodHasWordsNotAKey() {
        for (s in BotState.values()) {
            val w = WidgetSpoken.mood(s)
            assertTrue(s.toString(), w.isNotBlank())
        }
        assertEquals("waiting for you", WidgetSpoken.mood(BotState.APPROVAL))
        assertFalse("the engine key is not a word", WidgetSpoken.mood(BotState.APPROVAL) == BotState.APPROVAL.key)
    }

    @Test fun aWaitingAgentIsSaidWithItsStateAndTheCount() {
        val c = sample(WidgetSample.WAITING)
        assertEquals("Claude Code, waiting for your approval. 1 waiting for you", WidgetSpoken.top(c))
        assertEquals("1 waiting. Claude Code", WidgetSpoken.alert(c))
        assertTrue(WidgetSpoken.list(c).endsWith("1 waiting for you"))
    }

    @Test fun aWorkingAgentIsJustItsState() {
        val c = sample(WidgetSample.WORKING)
        assertEquals("Claude Code, working", WidgetSpoken.top(c))
        assertEquals(WidgetSpoken.tile(c.top!!), WidgetSpoken.top(c))
        assertEquals(c.headline, WidgetSpoken.list(c))
    }

    @Test fun theEmptyAndDisconnectedStatesAreSpokenToo() {
        val off = sample(WidgetSample.DISCONNECTED)
        assertEquals("Not connected. Waiting for your PC", WidgetSpoken.alert(off))
        assertTrue(WidgetSpoken.top(off).startsWith(off.headline))
        assertTrue(WidgetSpoken.top(sample(WidgetSample.EMPTY)).isNotBlank())
        assertEquals("All calm. Nothing needs you", WidgetSpoken.alert(sample(WidgetSample.EMPTY)))
    }

    @Test fun nothingSpokenIsMoreThanTheWidgetShows() {
        // Names, state words and counts only: a sentence never carries a command or a file.
        for (s in WidgetSample.values()) {
            val c = sample(s)
            for (text in listOf(WidgetSpoken.top(c), WidgetSpoken.alert(c), WidgetSpoken.list(c)) + c.tiles.map { WidgetSpoken.tile(it) }) {
                for (word in listOf("command", "path", "statusText", ".kt")) assertFalse("$s: $text", text.contains(word, ignoreCase = true))
            }
        }
    }
}
