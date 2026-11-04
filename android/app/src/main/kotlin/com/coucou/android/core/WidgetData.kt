package com.coucou.android.core

import com.coucou.android.link.LinkState
import com.coucou.android.link.PlanUsage
import com.coucou.android.link.PlanWindow
import com.coucou.android.link.SessionInfo
import com.coucou.android.link.UsageSnapshot
import com.coucou.android.mochi.BotState
import com.coucou.android.mochi.MochiConst
import com.coucou.android.mochi.Rgb
import java.time.Instant
import java.time.ZoneId
import java.time.format.TextStyle
import java.time.temporal.ChronoUnit
import java.util.Locale
import kotlin.math.roundToInt

/**
 * The one palette of every Widget: the colour of the glow behind Mochi, the card's gradient and 1dp border, the status dot, the badge
 * and the button tiles. Each tone has its colour in res/values/colors.xml (`widget_tone_<name>`, `widget_tint_<name>`,
 * `widget_border_<name>`), and a test keeps the two in step; no Widget picks a colour of its own for a state.
 *
 * - [DONE] green: finished, Mochi's happy face.
 * - [WORKING] blue.
 * - [ATTENTION] orange: waiting for the user (an approval or a question).
 * - [IDLE] soft grey: calm, "All calm", "No agents running".
 * - [MUTED] muted grey, with the "not connected" icon: the computer is not there.
 * - [TROUBLE] red: an agent stopped on an error or a limit.
 *
 * Taken from the app's own state colours ([MochiConst]), so a Widget and Mochi on Home always agree.
 */
enum class WidgetTone(val rgb: Rgb) {
    MUTED(MochiConst.C_SLEEPING),
    IDLE(Rgb(0.722, 0.741, 0.780)),
    WORKING(MochiConst.C_WORKING),
    ATTENTION(MochiConst.C_APPROVAL),
    DONE(MochiConst.C_FINISHED),
    TROUBLE(MochiConst.C_ERROR),
    ;

    /** Opaque ARGB. */
    val argb: Int get() = 0xFF000000.toInt() or (c(rgb.r) shl 16) or (c(rgb.g) shl 8) or c(rgb.b)

    companion object {
        private fun c(v: Double) = (v.coerceIn(0.0, 1.0) * 255).roundToInt()

        /** The tone of one agent's state; a computer that is not connected is always muted. */
        fun of(state: BotState, connected: Boolean = true): WidgetTone = if (!connected) MUTED else when (state) {
            BotState.APPROVAL, BotState.QUESTION -> ATTENTION
            BotState.WORKING, BotState.THINKING, BotState.SEARCHING -> WORKING
            BotState.FINISHED -> DONE
            BotState.ERROR, BotState.RATELIMIT, BotState.DIZZY -> TROUBLE
            BotState.IDLE, BotState.SLEEPING -> IDLE
        }
    }
}

/** One agent on a widget: who it is, a plain state word and its colour. Only names, state words and colours. */
data class WidgetTile(val pillId: String, val name: String, val state: BotState, val stateWord: String, val argb: Int) {
    /** The colour of its dot: the state's tone (the agent's own colour is [argb]). */
    val tone: WidgetTone get() = WidgetTone.of(state)
}

/**
 * The colours of plan usage: their own palette, so that a plan close to its limit never looks like "waiting for you" (orange) or like a
 * working agent (blue). Teal while there is room, yellow when getting close, red at the limit. In res/values/colors.xml as
 * `widget_usage_<name>`; a test keeps the two in step.
 */
enum class UsageTone(val rgb: Rgb) {
    CALM(Rgb(0.055, 0.561, 0.604)),
    CLOSE(Rgb(0.949, 0.816, 0.141)),
    LIMIT(Rgb(0.851, 0.176, 0.125)),
    ;

    /** Opaque ARGB. */
    val argb: Int get() = 0xFF000000.toInt() or (c(rgb.r) shl 16) or (c(rgb.g) shl 8) or c(rgb.b)

    private fun c(v: Double) = (v.coerceIn(0.0, 1.0) * 255).roundToInt()
}

/**
 * How a plan-usage percentage looks, in one place: the colour of the ring and of the bar, and the "Near limit" line. Below the red line
 * the percentage is shown small and normal with no warning; from [LIMIT_FROM] it is shown big and bold with "Near limit" and, when the
 * usage snapshot has one, when the window resets ("resets at 14:30"). Pure, so every boundary is a unit test.
 */
object PlanUsageLook {
    /** From this percentage (included) the usage is "getting close": yellow. */
    const val CLOSE_FROM = 75

    /** From this percentage (included) the usage is at the limit: red, with the warning. */
    const val LIMIT_FROM = 90

    /** What is shown and drawn: a percentage under 0 or over 100 is clamped. */
    fun clamp(pct: Int): Int = pct.coerceIn(0, 100)

    fun tone(pct: Int): UsageTone = when {
        clamp(pct) >= LIMIT_FROM -> UsageTone.LIMIT
        clamp(pct) >= CLOSE_FROM -> UsageTone.CLOSE
        else -> UsageTone.CALM
    }

    /** True from the red line: the Widget then shows the rate prominently. */
    fun nearLimit(pct: Int): Boolean = clamp(pct) >= LIMIT_FROM

    /**
     * When the window resets, as a clock time that stays true while nothing redraws the Widget: "resets at 14:30" today, "resets Fri 14:30"
     * within the next week, "resets Oct 21 14:30" later. Null when there is no reset time (0) or it has passed. [zone] is the phone's.
     */
    fun resetLine(resetsAtMs: Long, nowMs: Long, zone: ZoneId = ZoneId.systemDefault()): String? {
        if (resetsAtMs <= 0 || resetsAtMs <= nowMs) return null
        val at = Instant.ofEpochMilli(resetsAtMs).atZone(zone)
        val days = ChronoUnit.DAYS.between(Instant.ofEpochMilli(nowMs).atZone(zone).toLocalDate(), at.toLocalDate())
        val clock = "%02d:%02d".format(at.hour, at.minute)
        val locale = Locale.getDefault()
        return when {
            days == 0L -> Texts.t("usage_resets_at", "resets at %1\$s", clock)
            days < 7 -> Texts.t("usage_resets_day", "resets %1\$s %2\$s", at.dayOfWeek.getDisplayName(TextStyle.SHORT, locale), clock)
            else -> Texts.t("usage_resets_date", "resets %1\$s %2\$d %3\$s", at.month.getDisplayName(TextStyle.SHORT, locale), at.dayOfMonth, clock)
        }
    }

    /** "Near limit" (with the reset time when known) from the red line; null below it, where there is no warning. */
    fun note(pct: Int, resetsAtMs: Long, nowMs: Long, zone: ZoneId = ZoneId.systemDefault()): String? =
        if (!nearLimit(pct)) null else listOfNotNull(Texts.t("usage_near_limit", "Near limit"), resetLine(resetsAtMs, nowMs, zone)).joinToString(" · ")
}

/** The plan usage a ring or a bar shows: which plan and window, how much of it is used, and the warning line when it is near the limit. */
data class UsageRing(val plan: String, val window: String, val pct: Int, val note: String? = null) {
    /** The percentage to show, 0 to 100. */
    val shown: Int get() = PlanUsageLook.clamp(pct)

    /** 0 to 1, for the arc and the bar. */
    val fraction: Float get() = shown / 100f

    /** "Claude · 5 h". */
    val label: String get() = "$plan · $window"

    /** The colour of the ring and of the bar ([PlanUsageLook]). */
    val tone: UsageTone get() = PlanUsageLook.tone(pct)

    /** True from the red line: big and bold, with [note] under it. */
    val nearLimit: Boolean get() = PlanUsageLook.nearLimit(pct)
}

/** What the right side of Mochi Big shows: the plan usage rows, a calm "Plan usage is off", or "Not connected". Never nothing. */
enum class UsageSide { ROWS, OFF, NOT_CONNECTED }

/**
 * Everything the Widgets draw, as plain data so two pushes can be compared and the identical one skipped.
 * Built from the same sessions, order and wording as [GlanceBuilder], so the widgets never say anything the notification,
 * the tile and the first widget do not.
 */
data class WidgetContent(
    val headline: String,
    val tone: GlanceTone,
    val connected: Boolean,
    /** Requests and questions waiting for the user. */
    val waiting: Int,
    /** Most urgent first. Empty while the computer is not connected. */
    val tiles: List<WidgetTile>,
    /** The plan usage for the ring; null when the computer does not send it (its switch is off) or is not connected. */
    val ring: UsageRing? = null,
    /** Agent tasks finished today, counted on this phone only. */
    val today: Int = 0,
    /** Mochi Big's plan usage: Claude then Codex, each with its main window; empty when the computer sends none or is not connected. */
    val usageRows: List<UsageRing> = emptyList(),
    /** Every agent that runs, most urgent first (the [tiles] are its first few): the Team widget picks its own from it. */
    val roster: List<WidgetTile> = emptyList(),
) {
    /** Which of the three things Mochi Big's right side shows. */
    val usageSide: UsageSide get() = when {
        !connected -> UsageSide.NOT_CONNECTED
        usageRows.isEmpty() -> UsageSide.OFF
        else -> UsageSide.ROWS
    }

    /** The agent Solo shows. */
    val top: WidgetTile? get() = tiles.firstOrNull()

    /** The one clear line when there is no agent to list: the computer is not there, or nothing runs. Null when there are agents. */
    val emptyLine: String? get() = when {
        tiles.isNotEmpty() -> null
        !connected -> Texts.t("widget_waiting_computer", "Waiting for your computer")
        else -> Texts.t("widget_no_agents", "No agents running")
    }

    /** The Waiting Alert's line: "2 waiting" in orange, or a calm word. */
    val alertLine: String get() = when {
        !connected -> Texts.t("status_not_connected", "Not connected")
        waiting > 0 -> Texts.n("widget_n_waiting", waiting, "%1\$d waiting", "%1\$d waiting")
        else -> Texts.t("widget_all_calm", "All calm")
    }

    /** The line under the alert: who is waiting, or why there is nothing to say. */
    val alertSub: String get() = when {
        !connected -> Texts.t("widget_waiting_pc", "Waiting for your PC")
        waiting > 0 -> top?.name.orEmpty()
        else -> Texts.t("widget_nothing_needs_you", "Nothing needs you")
    }

    /** Mochi's face on the Today widget: pleased once something finished today, calm before. */
    val todayMood: BotState get() = if (today > 0) BotState.FINISHED else BotState.IDLE

    /** The Today widget glows green once something finished today, soft grey before. */
    val todayLook: WidgetTone get() = if (today > 0) WidgetTone.DONE else WidgetTone.IDLE

    /**
     * The look of the whole widget. Not connected: muted. Something waits for you: orange. Otherwise the most urgent agent's tone, and
     * the tiles are already in the order of [GlanceBuilder.rank] (waiting, then trouble, working, happy, idle): the top one sets the look.
     * Connected with nothing to list: idle grey.
     */
    val look: WidgetTone get() = when {
        !connected -> WidgetTone.MUTED
        waiting > 0 -> WidgetTone.ATTENTION
        else -> top?.let { WidgetTone.of(it.state) } ?: WidgetTone.IDLE
    }

    /** The state Mochi is drawn in: the top agent's, else calm when connected and asleep when not. */
    val mood: BotState get() = top?.state ?: if (connected) BotState.IDLE else BotState.SLEEPING
}

/**
 * A made-up state to look at every Widget without a computer: the debug build can pin one of these (see the preview receiver in
 * the debug source set). They go through the same [WidgetData.build] as the real thing, so a preview cannot drift from it.
 */
enum class WidgetSample(val key: String) {
    DISCONNECTED("disconnected"),
    EMPTY("empty"),
    WORKING("working"),
    WAITING("waiting"),
    DONE("done"),
    ;

    companion object {
        /** The sample called [key] (any case, spaces around ignored); null for anything else. */
        fun parse(key: String?): WidgetSample? = values().firstOrNull { it.key == key?.trim()?.lowercase() }
    }
}

/** The look of the summary widget, by the same rule as [WidgetContent.look]: its lines are already in the order of urgency. */
fun Glance.look(): WidgetTone = when {
    !connected -> WidgetTone.MUTED
    waiting > 0 -> WidgetTone.ATTENTION
    else -> lines.firstOrNull()?.let { WidgetTone.of(it.state) } ?: WidgetTone.IDLE
}

/** The state of Mochi's face on the summary widget: the most urgent agent's, else calm when connected and asleep when not. */
fun Glance.mood(): BotState = lines.firstOrNull()?.state ?: if (connected) BotState.IDLE else BotState.SLEEPING

object WidgetData {
    /** Rows on the List widget. */
    const val MAX_ROWS = 5
    private val FALLBACK = GlanceTone.CALM.argb

    fun build(
        glance: Glance,
        sessions: List<SessionInfo>,
        nameOf: (String) -> String,
        usage: UsageSnapshot? = null,
        today: Int = 0,
        nowMs: Long = 0L,
    ): WidgetContent {
        val roster = if (!glance.connected) emptyList() else sessions
            .sortedBy { GlanceBuilder.rank(it.state) }
            .map { WidgetTile(it.pillId, nameOf(it.pillId), it.state, GlanceBuilder.lineOf(it), colourOf(it)) }
        val tiles = roster.take(MAX_ROWS)
        val ring = if (glance.connected) ring(usage, nowMs) else null
        val rows = if (glance.connected) usageRows(usage, nowMs) else emptyList()
        return WidgetContent(glance.headline, glance.tone, glance.connected, glance.waiting, tiles, ring, today.coerceAtLeast(0), rows, roster)
    }

    /**
     * Up to two rows for Mochi Big: Claude, then Codex, each with its main window (five hours, else the week). A plan the computer
     * does not know has no row. The same data as the Usage Ring, with a window that has reset counted as zero ([PlanText]).
     */
    fun usageRows(usage: UsageSnapshot?, nowMs: Long): List<UsageRing> {
        usage ?: return emptyList()
        return listOf("Claude" to usage.claude, "Codex" to usage.codex).mapNotNull { (name, plan) ->
            plan?.fiveHour?.let { row(name, WINDOW_5H, it, nowMs) } ?: plan?.sevenDay?.let { row(name, WINDOW_WEEK, it, nowMs) }
        }
    }

    /**
     * The content a [WidgetSample] stands for, built like a real one. [nowMs] only sets when the sample plan windows reset.
     * [usagePct], when given, replaces Claude's five-hour usage (Mochi Big and the Usage Ring); null keeps the sample's own.
     */
    fun sample(which: WidgetSample, nowMs: Long = 0L, usagePct: Int? = null): WidgetContent {
        val link = if (which == WidgetSample.DISCONNECTED) LinkState.DISCONNECTED else LinkState.CONNECTED
        val sessions = when (which) {
            WidgetSample.DISCONNECTED, WidgetSample.EMPTY -> emptyList()
            WidgetSample.WORKING -> listOf(
                SessionInfo("integration_claude", "Claude Code", BotState.WORKING, "", 0, 0, 0L),
                SessionInfo("agent_codex", "Codex", BotState.THINKING, "", 0, 0, 0L),
                SessionInfo("agent_gemini", "Gemini CLI", BotState.IDLE, "", 0, 0, 0L),
            )
            WidgetSample.WAITING -> listOf(
                SessionInfo("integration_claude", "Claude Code", BotState.APPROVAL, "", 0, 0, 0L),
                SessionInfo("agent_codex", "Codex", BotState.WORKING, "", 0, 0, 0L),
                SessionInfo("agent_gemini", "Gemini CLI", BotState.FINISHED, "", 0, 0, 0L),
            )
            WidgetSample.DONE -> listOf(
                SessionInfo("integration_claude", "Claude Code", BotState.FINISHED, "", 0, 0, 0L),
                SessionInfo("agent_codex", "Codex", BotState.FINISHED, "", 0, 0, 0L),
            )
        }
        val approvals = if (which == WidgetSample.WAITING) 1 else 0
        val names = sessions.associate { it.pillId to it.agent }
        val glance = GlanceBuilder.build(true, link, "Your PC", sessions, approvals) { names[it] ?: "An agent" }
        fun plan(five: Int, week: Int) = PlanUsage(PlanWindow(five, nowMs + 2 * HOUR_MS), PlanWindow(week, nowMs + 3 * 24 * HOUR_MS))
        // Codex has only its week here, so the second row of Mochi Big reads "Codex · week".
        fun week(pct: Int) = PlanUsage(null, PlanWindow(pct, nowMs + 3 * 24 * HOUR_MS))
        val usage = if (usagePct != null && which != WidgetSample.DISCONNECTED) {
            // Debug preview of the near-limit look: Claude's five-hour window at [usagePct], reset in two hours; Codex stays as in the sample.
            UsageSnapshot(plan(usagePct, usagePct * 2 / 3), week(41))
        } else when (which) {
            WidgetSample.WORKING -> UsageSnapshot(plan(42, 18), week(41))
            WidgetSample.WAITING -> UsageSnapshot(plan(83, 61), week(93))
            WidgetSample.DONE -> UsageSnapshot(plan(24, 9), null)
            // No plan usage on these two, so the Usage Ring shows how it asks for the switch.
            WidgetSample.DISCONNECTED, WidgetSample.EMPTY -> null
        }
        val today = when (which) {
            WidgetSample.DISCONNECTED, WidgetSample.EMPTY -> 0
            WidgetSample.WORKING, WidgetSample.WAITING -> 3
            WidgetSample.DONE -> 5
        }
        return build(glance, sessions, { names[it] ?: "An agent" }, usage, today, nowMs)
    }

    private const val HOUR_MS = 3_600_000L

    /** The window names of a plan row, in the app's language ("5 h", "week"). */
    private val WINDOW_5H: String get() = Texts.t("usage_window_5h", "5 h")
    private val WINDOW_WEEK: String get() = Texts.t("usage_window_week", "week")

    /** One row: the percentage counted as zero once the window has reset, and the "Near limit" line with its reset time. */
    private fun row(plan: String, window: String, w: PlanWindow, nowMs: Long): UsageRing {
        val pct = PlanText.effectivePct(w, nowMs)
        return UsageRing(plan, window, pct, PlanUsageLook.note(pct, w.resetsAtMs, nowMs))
    }

    /** Claude's five-hour window first, then its week, then Codex; null when the computer sent none of them. */
    fun ring(usage: UsageSnapshot?, nowMs: Long): UsageRing? {
        usage ?: return null
        for ((name, plan) in listOf("Claude" to usage.claude, "Codex" to usage.codex)) {
            plan ?: continue
            plan.fiveHour?.let { return row(name, "5 h", it, nowMs) }
            plan.sevenDay?.let { return row(name, WINDOW_WEEK, it, nowMs) }
        }
        return null
    }

    /** The session's own colour, else its pill's, else grey. */
    private fun colourOf(s: SessionInfo): Int =
        parse(s.color) ?: parse(Pills.byId(s.pillId)?.colorHex) ?: FALLBACK

    /** "#RRGGBB" to opaque ARGB; null for anything else. */
    fun parse(hex: String?): Int? {
        val h = hex?.trim() ?: return null
        if (h.length != 7 || h[0] != '#') return null
        val digits = h.substring(1)
        // toIntOrNull accepts a sign, which is not a colour.
        if (!digits.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) return null
        return 0xFF000000.toInt() or digits.toInt(16)
    }
}
