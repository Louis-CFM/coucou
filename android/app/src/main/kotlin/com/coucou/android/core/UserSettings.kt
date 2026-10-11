package com.coucou.android.core

import com.coucou.android.mochi.BotState
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/** Where settings are kept (SharedPreferences in the app, a plain map in tests). */
interface KeyValueStore {
    fun getBoolean(key: String, default: Boolean): Boolean
    fun getInt(key: String, default: Int): Int
    fun getFloat(key: String, default: Float): Float
    fun getString(key: String, default: String): String
    fun put(key: String, value: Any)
}

/** Quiet hours: minutes since midnight. A window may cross midnight (22:00 to 08:00). */
data class QuietHours(val enabled: Boolean, val fromMin: Int, val toMin: Int) {
    fun isQuiet(minuteOfDay: Int): Boolean {
        if (!enabled || fromMin == toMin) return false
        return if (fromMin < toMin) minuteOfDay in fromMin until toMin
        else minuteOfDay >= fromMin || minuteOfDay < toMin
    }

    companion object {
        const val STEP = 30
        fun wrap(min: Int): Int = ((min % 1440) + 1440) % 1440
    }
}

/** What the user chose in Settings. Defaults keep the app as it was before the settings existed. */
data class UserSettings(
    val soundOn: Boolean = true,
    val volume: Float = com.coucou.android.sound.SoundVolume.DEFAULT,
    val notifyDone: Boolean = true,
    val quiet: QuietHours = QuietHours(false, 22 * 60, 8 * 60),
    /** Mochi's outfit on this phone: "computer" (follow the one chosen on the computer), "auto", "none" or an outfit. */
    val outfit: String = com.coucou.android.mochi.outfit.Wardrobe.FOLLOW,
    /** Use the relay when the computer is not reachable on this network (only matters when the pairing includes one). */
    val useRelay: Boolean = true,
) {
    companion object {
        private const val SOUND = "sound_on"
        private const val VOLUME = "sound_volume"
        private const val DONE = "notify_done"
        private const val Q_ON = "quiet_on"
        private const val Q_FROM = "quiet_from"
        private const val Q_TO = "quiet_to"
        private const val OUTFIT = "outfit_choice"
        private const val RELAY = "use_relay"

        fun load(store: KeyValueStore): UserSettings {
            val d = UserSettings()
            return UserSettings(
                soundOn = store.getBoolean(SOUND, d.soundOn),
                volume = com.coucou.android.sound.SoundVolume.clamp(store.getFloat(VOLUME, d.volume)),
                notifyDone = store.getBoolean(DONE, d.notifyDone),
                quiet = QuietHours(
                    store.getBoolean(Q_ON, d.quiet.enabled),
                    QuietHours.wrap(store.getInt(Q_FROM, d.quiet.fromMin)),
                    QuietHours.wrap(store.getInt(Q_TO, d.quiet.toMin)),
                ),
                outfit = com.coucou.android.mochi.outfit.Wardrobe.parseLocal(store.getString(OUTFIT, d.outfit)),
                useRelay = store.getBoolean(RELAY, d.useRelay),
            )
        }

        fun save(store: KeyValueStore, s: UserSettings) {
            store.put(SOUND, s.soundOn)
            store.put(VOLUME, com.coucou.android.sound.SoundVolume.clamp(s.volume))
            store.put(DONE, s.notifyDone)
            store.put(Q_ON, s.quiet.enabled)
            store.put(Q_FROM, QuietHours.wrap(s.quiet.fromMin))
            store.put(Q_TO, QuietHours.wrap(s.quiet.toMin))
            store.put(OUTFIT, com.coucou.android.mochi.outfit.Wardrobe.parseLocal(s.outfit))
            store.put(RELAY, s.useRelay)
        }
    }
}

/** What to do when a session changes state while the app may be in the background. */
data class Announce(val sound: Boolean, val notify: Boolean, val pill: Boolean) {
    companion object { val NONE = Announce(sound = false, notify = false, pill = false) }
}

object StatusPolicy {
    /** Finished, failed and rate limited are "news"; a question is more: it is waiting for the user. */
    private val NEWS = setOf(BotState.FINISHED, BotState.ERROR, BotState.RATELIMIT)

    /**
     * Only a change into one of those states counts, never the first picture after connecting
     * (previous == null), so sessions that ended long ago stay quiet.
     *
     * - The switch "when an agent finishes or fails" governs finished / failed / rate limited.
     * - Quiet hours silence those too (no sound, no pill) but the notice stays in the shade.
     *   A question is never silenced: like a permission request it needs the user.
     * - Inside Coucou the screen already shows everything: no notification, no pill. The sound stays.
     * - The notification is always posted quietly (shade only): the sound is Mochi's own and the pill
     *   is the on-screen alert, so nothing overlaps or rings twice.
     */
    fun announce(previous: BotState?, now: BotState, s: UserSettings, minuteOfDay: Int, appInForeground: Boolean): Announce {
        if (previous == null || previous == now) return Announce.NONE
        val question = now == BotState.QUESTION
        if (!question && now !in NEWS) return Announce.NONE
        if (!question && !s.notifyDone) return Announce.NONE
        val quiet = !question && s.quiet.isQuiet(minuteOfDay)
        return Announce(
            sound = s.soundOn && !quiet,
            notify = !appInForeground,
            pill = !appInForeground && !quiet,
        )
    }

    /** The approval sound and the like for a change into approval; unchanged behaviour, minus the first picture. */
    fun stateSoundWanted(previous: BotState?, now: BotState, s: UserSettings): Boolean =
        s.soundOn && previous != null && previous != now && now == BotState.APPROVAL
}

/** One decision made on this phone. Kept only on this phone. */
data class Decision(val agent: String, val tool: String, val command: String, val allowed: Boolean, val atMs: Long)

/** The phone's own list of decisions, newest first, at most 50. */
class DecisionLog(private val store: KeyValueStore, private val key: String = "decisions") {
    fun all(): List<Decision> {
        val raw = store.getString(key, "")
        if (raw.isEmpty()) return emptyList()
        return raw.split(ROW).mapNotNull { row ->
            val f = row.split(COL)
            if (f.size != 5) return@mapNotNull null
            val at = f[4].toLongOrNull() ?: return@mapNotNull null
            Decision(f[0], f[1], f[2], f[3] == "1", at)
        }
    }

    fun add(d: Decision) {
        val list = listOf(clean(d)) + all()
        store.put(key, list.take(MAX).joinToString(ROW) { listOf(it.agent, it.tool, it.command, if (it.allowed) "1" else "0", it.atMs).joinToString(COL) })
    }

    fun clear() = store.put(key, "")

    private fun clean(d: Decision) = d.copy(
        agent = strip(d.agent).take(64), tool = strip(d.tool).take(64), command = strip(d.command).take(COMMAND_MAX),
    )

    private fun strip(s: String) = s.replace(ROW, " ").replace(COL, " ")

    companion object {
        const val MAX = 50
        /** Only the start of a command is kept: a long one could carry something private. */
        const val COMMAND_MAX = 120
        private const val ROW = "\u001E"
        private const val COL = "\u001F"
    }
}

/** Days for the history list. */
object HistoryDays {
    enum class Day { TODAY, YESTERDAY, OTHER }

    fun classify(atMs: Long, nowMs: Long, zone: ZoneId): Pair<Day, LocalDate> {
        val date = Instant.ofEpochMilli(atMs).atZone(zone).toLocalDate()
        val today = Instant.ofEpochMilli(nowMs).atZone(zone).toLocalDate()
        return when (date) {
            today -> Day.TODAY to date
            today.minusDays(1) -> Day.YESTERDAY to date
            else -> Day.OTHER to date
        }
    }

    /** Consecutive decisions of the same day grouped together, keeping the newest-first order. */
    fun group(list: List<Decision>, nowMs: Long, zone: ZoneId): List<Pair<Pair<Day, LocalDate>, List<Decision>>> {
        val out = ArrayList<Pair<Pair<Day, LocalDate>, MutableList<Decision>>>()
        for (d in list) {
            val key = classify(d.atMs, nowMs, zone)
            if (out.isNotEmpty() && out.last().first.second == key.second) out.last().second.add(d)
            else out.add(key to mutableListOf(d))
        }
        return out
    }
}
