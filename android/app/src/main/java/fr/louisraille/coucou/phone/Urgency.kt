package fr.louisraille.coucou.phone

/**
 * How urgent a session's state is, higher first — the same order as the Mac's
 * MochiActivityState.urgency (which counts the other way, 0 = most urgent):
 * waiting for an OK, a question, something wrong (error, rate limit, dizzy),
 * working, finished, then everything else.
 */
internal fun urgencyOf(state: String): Int = when (state) {
    "approval" -> 5
    "question" -> 4
    "error", "ratelimit", "dizzy" -> 3
    "working", "thinking", "searching" -> 2
    "finished" -> 1
    else -> 0
}
