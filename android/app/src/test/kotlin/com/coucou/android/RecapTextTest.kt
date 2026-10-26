package com.coucou.android

import com.coucou.android.core.RecapText
import com.coucou.android.link.Recap
import java.io.File
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RecapTextTest {
    private val recap = Recap("2026-10-05", 340, 12, 40, 900, 210, 55, 20, 3, "Claude Code", "coucou")

    @Test fun durationsReadLikeTheRestOfTheApp() {
        assertEquals("45 min", RecapText.duration(45))
        assertEquals("2 h", RecapText.duration(120))
        assertEquals("5 h 40 min", RecapText.duration(340))
        assertEquals("0 min", RecapText.duration(-3))
    }

    @Test fun theWeekRunsMondayToSunday() {
        assertEquals("5 Oct – 11 Oct", RecapText.weekLabel("2026-10-05", Locale.ENGLISH))
        assertEquals("28 Dec – 3 Jan", RecapText.weekLabel("2026-12-28", Locale.ENGLISH))
        assertNull(RecapText.weekLabel("tomorrow"))
    }

    @Test fun theStatsComeInTheCardsOrder() {
        val s = RecapText.stats(recap)
        assertEquals(
            listOf("Time with agents", "Sessions", "Files changed", "Lines", "Commands run", "Permissions", "Most used", "Top project"),
            s.map { it.first },
        )
        assertEquals("5 h 40 min", s[0].second)
        assertEquals("+900 −210", s[3].second)
        assertEquals("20 allowed, 3 denied", s[5].second)
    }

    @Test fun anAgentAndAProjectThatWereNotSentAreLeftOut() {
        assertEquals(6, RecapText.stats(recap.copy(topAgent = null, project = null)).size)
        assertEquals(7, RecapText.stats(recap.copy(project = null)).size)
    }

    @Test fun theCardIsReadOnlyAndHeldInMemory() {
        val src = File("src/main/kotlin/com/coucou/android/ui/RecapPanel.kt").readText()
        assertFalse(src.contains("clickable") || src.contains("onClick"))
        val model = File("src/main/kotlin/com/coucou/android/app/AppModel.kt").readText()
        assertTrue(model.contains("var recap by mutableStateOf"))
        assertTrue(model.contains("if (Protocol.CAP_RECAP !in caps) recap = null"))
        // Never written anywhere.
        assertFalse(model.substringAfter("override fun onRecap").substringBefore("}").contains("store"))
        assertTrue(File("src/main/kotlin/com/coucou/android/MainActivity.kt").readText().contains("RecapPanel(model.recap)"))
    }
}
