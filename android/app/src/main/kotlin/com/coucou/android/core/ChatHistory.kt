package com.coucou.android.core

import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

/** One small text file; the app backs it with a private file, tests with memory. */
interface TextFile {
    fun read(): String?
    fun write(text: String)
    fun delete()
}

/**
 * The conversation as kept on the phone: a private file, never sent anywhere, with a Clear button.
 * Reading a damaged or unknown file gives an empty history rather than an error, and an answer
 * that was still arriving when the app closed is shown as interrupted.
 */
class ChatHistory(private val file: TextFile) {
    fun load(): List<ChatMessage> = decode(file.read())

    fun save(messages: List<ChatMessage>) {
        if (messages.isEmpty()) file.delete() else file.write(encode(messages))
    }

    fun clear() = file.delete()

    companion object {
        private const val VERSION = 1

        fun encode(messages: List<ChatMessage>): String {
            val a = JSONArray()
            for (m in messages.takeLast(ChatSession.MAX_MESSAGES)) {
                val o = JSONObject().put("id", m.id).put("role", m.role.name.lowercase()).put("text", m.text)
                    .put("status", m.status.name.lowercase())
                m.reason?.let { o.put("reason", it) }
                a.put(o)
            }
            return JSONObject().put("v", VERSION).put("messages", a).toString()
        }

        fun decode(text: String?): List<ChatMessage> {
            if (text.isNullOrBlank()) return emptyList()
            return try {
                val o = JSONObject(text)
                if (o.optInt("v", 0) != VERSION) return emptyList()
                val a = o.getJSONArray("messages")
                (0 until a.length()).mapNotNull { message(a.optJSONObject(it)) }.takeLast(ChatSession.MAX_MESSAGES)
            } catch (_: JSONException) {
                emptyList()
            }
        }

        private fun message(o: JSONObject?): ChatMessage? {
            o ?: return null
            val id = o.optString("id", "")
            val role = ChatRole.entries.firstOrNull { it.name.equals(o.optString("role"), ignoreCase = true) } ?: return null
            if (id.isBlank()) return null
            var status = ChatStatus.entries.firstOrNull { it.name.equals(o.optString("status"), ignoreCase = true) } ?: ChatStatus.DONE
            var reason = o.optString("reason", "").ifEmpty { null }
            if (status == ChatStatus.STREAMING) { status = ChatStatus.FAILED; reason = "interrupted" }
            return ChatMessage(id, role, o.optString("text", "").take(ChatSession.MAX_TEXT), status, reason)
        }
    }
}
