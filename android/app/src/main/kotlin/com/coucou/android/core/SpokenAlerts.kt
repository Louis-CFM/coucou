package com.coucou.android.core

import com.coucou.android.mochi.BotState

/**
 * "Spoken alerts" (Settings > Sound, off by default): the phone says one short line, with its own voice, when an agent needs the user (a
 * permission request or a question) or finishes: "Claude Code needs your approval". The line names the agent and the kind of event, and
 * nothing else: never a command, a diff, a file name or a message. Speaking is all it does: nothing is answered or approved by it.
 *
 * It stays silent in Do Not Disturb, when the ringer is silent or on vibrate, during a call, and when the phone has no voice of its own
 * (one that needs no network) for the app's language. The rules are here, pure; `app/SpokenAlerts.kt` only asks Android and speaks.
 */
object SpokenAlertPolicy {
    enum class Kind { APPROVAL, QUESTION, FINISHED }

    /** What the phone is doing right now, asked only once an event is worth a line. */
    data class Phone(val dndOn: Boolean, val ringerNormal: Boolean, val inCall: Boolean, val hasVoice: Boolean)

    /**
     * Only a change into one of the three states is an event, never the first picture after connecting (previous == null), so a request
     * that was already waiting, or a session that ended long ago, is not announced when the link comes back.
     */
    fun kind(previous: BotState?, now: BotState): Kind? {
        if (previous == null || previous == now) return null
        return when (now) {
            BotState.APPROVAL -> Kind.APPROVAL
            BotState.QUESTION -> Kind.QUESTION
            BotState.FINISHED -> Kind.FINISHED
            else -> null
        }
    }

    /**
     * Why nothing is said (for the log), or null when the line may be spoken. A finish follows the notices' own rules: an agent the user
     * muted and the quiet hours stay quiet. A request or a question is never held back by those, like their notification.
     */
    fun blocker(enabled: Boolean, kind: Kind, pillId: String, s: UserSettings, minuteOfDay: Int, phone: () -> Phone): String? {
        if (!enabled) return "switch is off"
        if (kind == Kind.FINISHED && pillId in s.mutedAgents) return "the agent is muted"
        if (kind == Kind.FINISHED && s.quiet.isQuiet(minuteOfDay)) return "quiet hours"
        val p = phone()
        return when {
            p.dndOn -> "Do Not Disturb is on"
            !p.ringerNormal -> "the ringer is silent or on vibrate"
            p.inCall -> "a call is going on"
            !p.hasVoice -> "no voice for this language"
            else -> null
        }
    }

    /** The whole decision: the line to say, or null. [phone] is asked only when everything else allows the line. */
    fun decide(
        enabled: Boolean, previous: BotState?, now: BotState, pillId: String, sessionName: String?,
        s: UserSettings, minuteOfDay: Int, phone: () -> Phone,
    ): String? {
        val kind = kind(previous, now) ?: return null
        if (blocker(enabled, kind, pillId, s, minuteOfDay, phone) != null) return null
        return line(kind, name(pillId, sessionName))
    }

    /** The one sentence: the agent and the kind of event. */
    fun line(kind: Kind, agent: String): String = when (kind) {
        Kind.APPROVAL -> Texts.t("spoken_approval", "%1\$s needs your approval", agent)
        Kind.QUESTION -> Texts.t("spoken_question", "%1\$s has a question for you", agent)
        Kind.FINISHED -> Texts.t("spoken_finished", "%1\$s has finished", agent)
    }

    const val NAME_MAX = 40

    /**
     * The name that is said: the catalog's for a known agent ("integration_claude#2" is Claude Code), else the session's own name cut down to
     * letters, digits and spaces, so a name the computer made up cannot carry a path or a command into the sentence.
     */
    fun name(pillId: String, sessionName: String?): String {
        Pills.byId(pillId.substringBefore('#'))?.let { return it.name }
        val clean = sessionName.orEmpty().map { if (it.isLetterOrDigit()) it else ' ' }.joinToString("")
            .trim().replace(Regex(" +"), " ").take(NAME_MAX).trim()
        return clean.ifEmpty { Texts.t("agent_an_title", "An agent") }
    }

    /** A voice the phone's engine offers, as far as the choice needs to know it. */
    data class Voice(val name: String, val language: String, val country: String, val needsNetwork: Boolean, val installed: Boolean)

    /**
     * The voice for the app's language ([tag], a BCP 47 tag such as "fr", "pt-BR" or "zh-Hant"), or null when the phone has none: only a
     * voice that is installed and works without the network counts, so speaking never makes a network call. The same country is
     * preferred ("pt-BR" over "pt-PT"); for Chinese the script decides the countries, so Traditional is never read with a Mainland voice.
     */
    fun pickVoice(voices: List<Voice>, tag: String): Voice? {
        val parts = tag.split('-', '_').filter { it.isNotEmpty() }
        val language = normal(parts.firstOrNull() ?: return null)
        val script = parts.firstOrNull { it.length == 4 }?.lowercase()
        val country = parts.drop(1).firstOrNull { it.length == 2 }?.uppercase()
        val usable = voices.filter { it.installed && !it.needsNetwork && normal(it.language) == language }
            .sortedBy { it.name }
        val required = when (script) {
            "hant" -> setOf("TW", "HK", "MO")
            "hans" -> setOf("CN", "SG")
            else -> null
        }
        val allowed = if (required == null) usable else usable.filter { it.country.uppercase() in required }
        return allowed.firstOrNull { country != null && it.country.uppercase() == country } ?: allowed.firstOrNull()
    }

    /** Java's old codes and the engines' own ("in" for Indonesian, "cmn" for Chinese) as the app's tags write them. */
    private fun normal(language: String): String = when (val l = language.lowercase()) {
        "in", "ind" -> "id"
        "cmn", "zho", "chi" -> "zh"
        "fra", "fre" -> "fr"
        "deu", "ger" -> "de"
        "spa" -> "es"
        "por" -> "pt"
        "ita" -> "it"
        "rus" -> "ru"
        "jpn" -> "ja"
        "kor" -> "ko"
        "tur" -> "tr"
        "tha" -> "th"
        "ara" -> "ar"
        "hin" -> "hi"
        "ben" -> "bn"
        "eng" -> "en"
        else -> l
    }
}

/**
 * Never the same event twice. The link sends the whole list again after a reconnect and repeats a session whenever one of its lines
 * changes; a state that flickers (approval, working, approval within a moment) is one event to the ear. So an agent's same kind of event
 * is said at most once per [GAP_MS], and what was said is remembered across reconnects (in memory only).
 */
class SpokenAlertBook {
    private val last = HashMap<String, Pair<SpokenAlertPolicy.Kind, Long>>()

    /** True the first time; false for the same agent and kind again within [GAP_MS]. Saying it is the caller's next step. */
    fun firstTime(pillId: String, kind: SpokenAlertPolicy.Kind, nowMs: Long): Boolean {
        val before = last[pillId]
        if (before != null && before.first == kind && nowMs - before.second in 0 until GAP_MS) return false
        if (last.size >= MAX && pillId !in last) last.remove(last.minByOrNull { it.value.second }?.key)
        last[pillId] = kind to nowMs
        return true
    }

    fun clear() = last.clear()

    companion object {
        const val GAP_MS = 8_000L
        const val MAX = 32
    }
}
