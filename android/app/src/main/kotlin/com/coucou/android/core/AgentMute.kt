package com.coucou.android.core

/**
 * "Mute this agent's notices": which agents stay quiet when they finish, fail or hit a limit (the sound, the notification and the pill that
 * [StatusPolicy] would give). Only those state notices. A permission request and a question are never muted, whatever is chosen here, and the
 * rule that says so is in [StatusPolicy.announce]. The choice is kept on the phone as a short list of catalog ids.
 */
object AgentMute {
    /** The agents that can be muted: the same list as the Team widget's. */
    val candidates: List<PillDefinition> get() = TeamChoice.candidates

    private val ids: Set<String> get() = candidates.map { it.id }.toSet()

    /** The muted agents read back; anything that is not a catalog agent (a stale value, a hand-edited file) is dropped. */
    fun decode(raw: String?): Set<String> = raw.orEmpty().split(',').map { it.trim() }.filter { it in ids }.toSet()

    fun encode(muted: Set<String>): String = candidates.map { it.id }.filter { it in muted }.joinToString(",")

    /** [muted] with [id] muted or not; an id that is not a catalog agent changes nothing. */
    fun with(muted: Set<String>, id: String, mute: Boolean): Set<String> = when {
        id !in ids -> muted
        mute -> muted + id
        else -> muted - id
    }
}
