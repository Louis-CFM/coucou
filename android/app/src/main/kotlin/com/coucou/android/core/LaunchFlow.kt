package com.coucou.android.core

import com.coucou.android.link.LaunchProject
import com.coucou.android.link.Protocol

/** Whether a new Claude Code session can be asked for right now, and if not, what the sheet says instead. */
enum class LaunchAvailability {
    /** The computer cannot be reached at the moment. */
    NOT_CONNECTED,
    /** The computer did not offer it: an older Coucou, a Mac, or its switch is off. */
    NOT_OFFERED,
    /** Offered, but the computer has no project to pick yet. */
    NO_PROJECTS,
    READY,
}

/** What became of the request the user sent. */
sealed interface LaunchOutcome {
    data object Idle : LaunchOutcome
    /** Sent to the computer; its answer is awaited. [project] is the folder's name, for the sentence that follows. */
    data class Sending(val id: String, val project: String) : LaunchOutcome
    /** The computer opened the terminal. */
    data class Sent(val project: String) : LaunchOutcome
    /** The computer said no; [reason] is its word (`off`, `unknown_project`, `rate`, `failed`...). */
    data class Refused(val reason: String) : LaunchOutcome
    /** Nothing came back in time: the session may or may not have started. */
    data object NoAnswer : LaunchOutcome
    /** It never left the phone (the link was down). */
    data object NotSent : LaunchOutcome
}

/**
 * Starting a Claude Code session on the computer from the phone (docs/ANDROID_LINK.md, capability `launch`), pure so each rule is a unit
 * test. The phone picks a project out of the computer's list and sends that project's id and the user's words; it never sends a path,
 * and nothing is sent before the screen-lock check (the caller's).
 */
object LaunchFlow {
    /** How long the phone waits for the computer's answer before saying there was none. */
    const val ANSWER_WAIT_MS = 10_000L

    fun availability(connected: Boolean, offered: Boolean, projects: List<LaunchProject>): LaunchAvailability = when {
        !connected -> LaunchAvailability.NOT_CONNECTED
        !offered -> LaunchAvailability.NOT_OFFERED
        projects.isEmpty() -> LaunchAvailability.NO_PROJECTS
        else -> LaunchAvailability.READY
    }

    /** The project that is picked: the user's choice while the computer still lists it, else the first (the most recent). */
    fun pick(projects: List<LaunchProject>, chosen: String?): LaunchProject? =
        projects.firstOrNull { it.id == chosen } ?: projects.firstOrNull()

    /** The words as they are sent: control characters (a line break too) become spaces, as the computer would make them; trimmed. */
    fun clean(prompt: String): String = prompt.map { if (it.isISOControl()) ' ' else it }.joinToString("").trim()

    enum class Problem { EMPTY, TOO_LONG }

    /** Why these words cannot be sent, or null. The computer has the same two rules. */
    fun problem(prompt: String): Problem? {
        val text = clean(prompt)
        return when {
            text.isEmpty() -> Problem.EMPTY
            text.codePointCount(0, text.length) > Protocol.LAUNCH_MAX_TEXT -> Problem.TOO_LONG
            else -> null
        }
    }

    /** Send is offered: everything is there and no request is on its way. */
    fun canSend(availability: LaunchAvailability, project: LaunchProject?, prompt: String, outcome: LaunchOutcome): Boolean =
        availability == LaunchAvailability.READY && project != null && problem(prompt) == null && outcome !is LaunchOutcome.Sending

    /**
     * What goes to the computer, or null when it may not be sent: the id of a project **of the list** and the cleaned words. A project
     * that is not in the list (it changed while the sheet was open) is never sent.
     */
    fun request(projects: List<LaunchProject>, projectId: String, prompt: String): Pair<LaunchProject, String>? {
        val project = projects.firstOrNull { it.id == projectId } ?: return null
        if (problem(prompt) != null) return null
        return project to clean(prompt)
    }

    /** A new id for a request: 16 hex characters. */
    fun newId(random: java.util.Random): String = (0 until 16).joinToString("") { "0123456789abcdef"[random.nextInt(16)].toString() }

    /** The answer for the request that is waiting; an answer for another id changes nothing. */
    fun onResult(now: LaunchOutcome, id: String, ok: Boolean, reason: String): LaunchOutcome = when {
        now !is LaunchOutcome.Sending || now.id != id -> now
        ok -> LaunchOutcome.Sent(now.project)
        else -> LaunchOutcome.Refused(reason)
    }

    /** No answer after [ANSWER_WAIT_MS], or the link dropped while waiting. */
    fun onSilence(now: LaunchOutcome, id: String? = null): LaunchOutcome =
        if (now is LaunchOutcome.Sending && (id == null || now.id == id)) LaunchOutcome.NoAnswer else now

    /** For the lock prompt: the project and the start of the words, so the user sees what is about to be sent. */
    fun summary(project: LaunchProject, prompt: String): String = "${project.name}: ${clean(prompt).take(SUMMARY_MAX)}"

    const val SUMMARY_MAX = 120

    /** Why the computer refused, in the user's words. An unknown reason gets the plain sentence. */
    fun refusal(reason: String): String = when (reason) {
        "off" -> Texts.t("launch_refused_off", "Your computer no longer allows this. Turn it back on there, in Settings > Android phone.")
        "unknown_project" -> Texts.t("launch_refused_project", "This project is no longer in your computer's list.")
        "rate" -> Texts.t("launch_refused_rate", "Too many sessions were started in a short time. Try again in a few minutes.")
        "failed" -> Texts.t("launch_refused_failed", "Your computer couldn't open a terminal in this project.")
        else -> Texts.t("launch_refused_other", "Your computer refused to start the session.")
    }
}
