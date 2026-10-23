package com.coucou.android.core

import com.coucou.android.mochi.BotState

/**
 * What TalkBack says for a Widget: whole sentences for the parts that are tapped, built from the same words the Widget shows (agent
 * names, state words, counts), so the spoken text can never say more than the screen does. Pure.
 */
object WidgetSpoken {
    /** Mochi's mood in plain words ("waiting for you"), not the engine's key ("approval"). */
    fun mood(state: BotState): String = when (state) {
        BotState.IDLE -> Texts.t("mood_calm", "calm")
        BotState.WORKING -> Texts.t("mood_working", "working")
        BotState.THINKING -> Texts.t("mood_thinking", "thinking")
        BotState.SEARCHING -> Texts.t("mood_searching", "searching")
        BotState.APPROVAL -> Texts.t("mood_waiting", "waiting for you")
        BotState.QUESTION -> Texts.t("mood_question", "has a question")
        BotState.ERROR -> Texts.t("mood_error", "in trouble")
        BotState.FINISHED -> Texts.t("mood_happy", "happy")
        BotState.RATELIMIT -> Texts.t("mood_limit", "at a limit")
        BotState.SLEEPING -> Texts.t("mood_asleep", "asleep")
        BotState.DIZZY -> Texts.t("mood_dizzy", "dizzy")
    }

    /** One agent: "Claude Code, waiting for your approval". */
    fun tile(t: WidgetTile): String = SpokenLabels.agent(t.name, t.stateWord, null)

    /** The tapped card of Solo and Mood: the top agent, or the headline when there is none; with what waits for you. */
    fun top(c: WidgetContent): String {
        val base = c.top?.let { tile(it) } ?: SpokenLabels.agent(c.headline, c.emptyLine.orEmpty(), null)
        return if (c.waiting > 0 && c.top != null) "$base. ${Texts.n("spoken_waiting_you", c.waiting, "%1\$d waiting for you", "%1\$d waiting for you")}" else base
    }

    /** Waiting Alert: "1 waiting. Claude Code", "All calm. Nothing needs you", "Not connected. Waiting for your PC". */
    fun alert(c: WidgetContent): String = "${c.alertLine}. ${c.alertSub}"

    /** The header of the list. */
    fun list(c: WidgetContent): String =
        if (c.waiting > 0) "${c.headline}. ${Texts.n("spoken_waiting_you", c.waiting, "%1\$d waiting for you", "%1\$d waiting for you")}" else c.headline
}
