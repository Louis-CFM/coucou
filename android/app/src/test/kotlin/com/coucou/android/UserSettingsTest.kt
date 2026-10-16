package com.coucou.android

import com.coucou.android.core.Announce
import com.coucou.android.core.Decision
import com.coucou.android.core.DecisionLog
import com.coucou.android.core.HistoryDays
import com.coucou.android.core.KeyValueStore
import com.coucou.android.core.QuietHours
import com.coucou.android.core.StatusPolicy
import com.coucou.android.core.UserSettings
import com.coucou.android.mochi.BotState
import java.time.ZoneId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UserSettingsTest {
    private class Memory : KeyValueStore {
        val map = HashMap<String, Any>()
        override fun getBoolean(key: String, default: Boolean) = map[key] as? Boolean ?: default
        override fun getInt(key: String, default: Int) = map[key] as? Int ?: default
        override fun getFloat(key: String, default: Float) = map[key] as? Float ?: default
        override fun getString(key: String, default: String) = map[key] as? String ?: default
        override fun put(key: String, value: Any) { map[key] = value }
    }

    private val noon = 12 * 60
    private val night = 23 * 60
    private val s = UserSettings()

    // ── settings ────────────────────────────────────────────────────────────

    @Test fun defaultsKeepTheAppAsItWas() {
        val loaded = UserSettings.load(Memory())
        assertTrue(loaded.soundOn)
        assertEquals(0.12f, loaded.volume, 0f)
        assertTrue(loaded.notifyDone)
        assertFalse(loaded.quiet.enabled)
    }

    @Test fun theRelayIsUsedByDefaultAndTheChoiceSurvivesARestart() {
        assertTrue("on by default: it only matters when the pairing has a relay", UserSettings.load(Memory()).useRelay)
        val disk = Memory()
        UserSettings.save(disk, UserSettings(useRelay = false))
        assertFalse(UserSettings.load(disk).useRelay)
    }

    @Test fun settingsSurviveARestart() {
        val disk = Memory()
        UserSettings.save(disk, UserSettings(soundOn = false, volume = 0.05f, notifyDone = false, quiet = QuietHours(true, 21 * 60, 7 * 60 + 30)))
        val back = UserSettings.load(disk)
        assertFalse(back.soundOn)
        assertEquals(0.05f, back.volume, 0f)
        assertFalse(back.notifyDone)
        assertEquals(QuietHours(true, 21 * 60, 7 * 60 + 30), back.quiet)
    }

    @Test fun volumeNeverExceedsTheSpecMaximum() {
        val disk = Memory()
        UserSettings.save(disk, UserSettings(volume = 9f))
        assertEquals(0.2f, UserSettings.load(disk).volume, 0f)
    }

    @Test fun quietHoursCrossMidnight() {
        val q = QuietHours(true, 22 * 60, 8 * 60)
        assertTrue(q.isQuiet(23 * 60))
        assertTrue(q.isQuiet(3 * 60))
        assertFalse(q.isQuiet(8 * 60))
        assertFalse(q.isQuiet(noon))
        assertTrue(q.isQuiet(22 * 60))
    }

    @Test fun quietHoursWithinTheDayAndWhenOff() {
        assertTrue(QuietHours(true, 13 * 60, 14 * 60).isQuiet(13 * 60 + 30))
        assertFalse(QuietHours(true, 13 * 60, 14 * 60).isQuiet(noon))
        assertFalse(QuietHours(false, 22 * 60, 8 * 60).isQuiet(night))
        assertFalse(QuietHours(true, 9 * 60, 9 * 60).isQuiet(9 * 60)) // an empty window is never quiet
        assertEquals(23 * 60 + 30, QuietHours.wrap(-30))
        assertEquals(30, QuietHours.wrap(24 * 60 + 30))
    }

    // ── what to announce ────────────────────────────────────────────────────

    @Test fun finishingAnnouncesWhenYouAreElsewhere() {
        assertEquals(Announce(sound = true, notify = true, pill = true), StatusPolicy.announce(BotState.WORKING, BotState.FINISHED, s, noon, appInForeground = false))
        assertEquals(Announce(sound = true, notify = true, pill = true), StatusPolicy.announce(BotState.WORKING, BotState.ERROR, s, noon, false))
    }

    @Test fun theFirstPictureAfterConnectingIsQuiet() {
        for (st in listOf(BotState.FINISHED, BotState.ERROR, BotState.QUESTION, BotState.RATELIMIT)) {
            assertEquals(Announce.NONE, StatusPolicy.announce(null, st, s, noon, false))
        }
    }

    @Test fun ordinaryWorkIsNotNews() {
        assertEquals(Announce.NONE, StatusPolicy.announce(BotState.IDLE, BotState.WORKING, s, noon, false))
        assertEquals(Announce.NONE, StatusPolicy.announce(BotState.FINISHED, BotState.FINISHED, s, noon, false))
        assertEquals(Announce.NONE, StatusPolicy.announce(BotState.WORKING, BotState.APPROVAL, s, noon, false))
    }

    @Test fun insideTheAppNothingPopsUpButTheSoundStays() {
        assertEquals(Announce(sound = true, notify = false, pill = false), StatusPolicy.announce(BotState.WORKING, BotState.FINISHED, s, noon, appInForeground = true))
    }

    @Test fun theSwitchTurnsFinishedAndFailedOffButNotQuestions() {
        val off = s.copy(notifyDone = false)
        assertEquals(Announce.NONE, StatusPolicy.announce(BotState.WORKING, BotState.FINISHED, off, noon, false))
        assertEquals(Announce.NONE, StatusPolicy.announce(BotState.WORKING, BotState.ERROR, off, noon, false))
        assertTrue(StatusPolicy.announce(BotState.WORKING, BotState.QUESTION, off, noon, false).notify)
    }

    @Test fun quietHoursKeepTheNoticeInTheShadeWithoutSoundOrPill() {
        val quiet = s.copy(quiet = QuietHours(true, 22 * 60, 8 * 60))
        assertEquals(Announce(sound = false, notify = true, pill = false), StatusPolicy.announce(BotState.WORKING, BotState.FINISHED, quiet, night, false))
        // A question needs the user: quiet hours do not hide it.
        assertEquals(Announce(sound = true, notify = true, pill = true), StatusPolicy.announce(BotState.WORKING, BotState.QUESTION, quiet, night, false))
    }

    @Test fun soundOffMeansNoSoundAnywhere() {
        val mute = s.copy(soundOn = false)
        assertFalse(StatusPolicy.announce(BotState.WORKING, BotState.FINISHED, mute, noon, false).sound)
        assertFalse(StatusPolicy.stateSoundWanted(BotState.WORKING, BotState.APPROVAL, mute))
        assertTrue(StatusPolicy.stateSoundWanted(BotState.WORKING, BotState.APPROVAL, s))
        assertFalse(StatusPolicy.stateSoundWanted(null, BotState.APPROVAL, s))
    }

    // ── decision history ────────────────────────────────────────────────────

    @Test fun historyKeepsNewestFirstAndAtMostFifty() {
        val log = DecisionLog(Memory())
        for (i in 1..60) log.add(Decision("Claude", "Bash", "cmd $i", allowed = i % 2 == 0, atMs = i.toLong()))
        val all = log.all()
        assertEquals(DecisionLog.MAX, all.size)
        assertEquals("cmd 60", all.first().command)
        assertEquals("cmd 11", all.last().command)
        assertTrue(all.first().allowed)
        assertFalse(all[1].allowed)
    }

    @Test fun historyCutsLongCommandsAndSurvivesOddCharacters() {
        val disk = Memory()
        DecisionLog(disk).add(Decision("A\u001Eb", "Bash", "x".repeat(500) + "\u001Fy\nz", allowed = false, atMs = 5))
        val d = DecisionLog(disk).all().single()
        assertEquals(DecisionLog.COMMAND_MAX, d.command.length)
        assertEquals("A b", d.agent)
        assertFalse(d.allowed)
    }

    @Test fun clearingEmptiesTheHistory() {
        val log = DecisionLog(Memory())
        log.add(Decision("A", "Bash", "ls", true, 1))
        log.clear()
        assertTrue(log.all().isEmpty())
    }

    @Test fun historyIsGroupedByDay() {
        val zone = ZoneId.of("UTC")
        val now = java.time.ZonedDateTime.of(2026, 10, 9, 15, 0, 0, 0, zone).toInstant().toEpochMilli()
        fun at(day: Int, hour: Int) = java.time.ZonedDateTime.of(2026, 10, day, hour, 0, 0, 0, zone).toInstant().toEpochMilli()
        val list = listOf(
            Decision("A", "Bash", "1", true, at(9, 14)), Decision("A", "Bash", "2", true, at(9, 1)),
            Decision("A", "Bash", "3", false, at(8, 23)), Decision("A", "Bash", "4", false, at(2, 10)),
        )
        val groups = HistoryDays.group(list, now, zone)
        assertEquals(listOf(HistoryDays.Day.TODAY, HistoryDays.Day.YESTERDAY, HistoryDays.Day.OTHER), groups.map { it.first.first })
        assertEquals(listOf(2, 1, 1), groups.map { it.second.size })
    }
    @Test fun theOutfitChoiceIsKeptAndDefaultsToTheComputers() {
        val m = Memory()
        assertEquals("computer", UserSettings.load(m).outfit)
        UserSettings.save(m, UserSettings(outfit = "crown"))
        assertEquals("crown", UserSettings.load(m).outfit)
        UserSettings.save(m, UserSettings(outfit = "auto"))
        assertEquals("auto", UserSettings.load(m).outfit)
    }

    @Test fun anOutfitChoiceNoBuildKnowsFollowsTheComputer() {
        val m = Memory()
        m.map["outfit_choice"] = "topHat"
        assertEquals("computer", UserSettings.load(m).outfit)
        UserSettings.save(m, UserSettings(outfit = "<script>"))
        assertEquals("computer", m.map["outfit_choice"])
    }
}
