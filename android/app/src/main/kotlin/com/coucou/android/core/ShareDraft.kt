package com.coucou.android.core

import com.coucou.android.link.Protocol

/**
 * "Share to Coucou": text shared from another app lands in the chat box as a draft, never sent by itself. This is the pure part: how the shared
 * text is cleaned, what to do for the state the chat is in, and the one-shot slot that carries the draft from the share target to the chat screen
 * inside the process. Other apps can start the share target, so the text is only ever treated as typed text: it is cut to the chat's limit, stripped
 * of control characters, and it goes into the box where the user reads it and taps send (or not).
 */
class ShareDraft(private val clock: () -> Long = System::currentTimeMillis) {
    private var text: String? = null
    private var at = 0L

    /** Keeps the cleaned [raw] as the draft (the last share wins); a blank or missing text keeps nothing. */
    @Synchronized
    fun offer(raw: String?) {
        text = clean(raw)
        at = clock()
    }

    /** The draft once, if it is fresh; null for everything else (nothing shared, already taken, too old). */
    @Synchronized
    fun take(): String? {
        val t = text ?: return null
        val fresh = clock() - at <= TTL_MS
        text = null
        return if (fresh) t else null
    }

    /** True while a fresh draft waits: the main screen then opens on Chat, where it is put in the box. */
    @Synchronized
    fun pending(): Boolean = text != null && clock() - at <= TTL_MS

    enum class Outcome { KEEP_AND_OPEN_CHAT, NOTHING_TO_SHARE, NOT_PAIRED, CHAT_UNAVAILABLE }

    companion object {
        /** A share is opened a few seconds after the tap, but the link may need a moment to come back first. */
        const val TTL_MS = 120_000L

        /** More than this is cut before it is even looked at, so a huge share costs nothing. */
        const val MAX_INPUT = 100_000

        /** The shared text as a draft: line breaks unified, control characters dropped, trimmed, cut to the chat limit; null when nothing is left. */
        fun clean(raw: String?): String? {
            raw ?: return null
            val sb = StringBuilder()
            var i = 0
            val s = raw.take(MAX_INPUT)
            while (i < s.length) {
                val ch = s[i]
                when {
                    ch == '\r' -> { sb.append('\n'); if (i + 1 < s.length && s[i + 1] == '\n') i++ }
                    ch == '\n' || ch == '\t' -> sb.append(ch)
                    ch.isISOControl() || ch == ' ' || ch == ' ' || ch == '‮' || ch == '‭' || ch == '​' -> {}
                    else -> sb.append(ch)
                }
                i++
            }
            val t = sb.toString().trim()
            if (t.isEmpty()) return null
            return t.take(Protocol.CHAT_MAX_TEXT).trimEnd()
        }

        /**
         * What the share target does. A computer that is paired but not reachable yet keeps the draft and opens the chat (it explains itself and
         * receives the draft when the link is back); a chat the computer does not offer says so and keeps nothing.
         */
        fun decide(hasText: Boolean, state: ChatTabState): Outcome = when {
            !hasText -> Outcome.NOTHING_TO_SHARE
            state == ChatTabState.NOT_PAIRED -> Outcome.NOT_PAIRED
            state == ChatTabState.CHAT_OFF || state == ChatTabState.NO_MODELS -> Outcome.CHAT_UNAVAILABLE
            else -> Outcome.KEEP_AND_OPEN_CHAT
        }

        /** How a draft is put in a box that may already hold text: after it, on a new line. Cut to the chat limit. */
        fun into(existing: String, draft: String): String =
            (if (existing.isBlank()) draft else existing.trimEnd() + "\n" + draft).take(Protocol.CHAT_MAX_TEXT)
    }
}
