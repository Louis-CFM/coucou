package fr.louisraille.coucou.phone

import android.graphics.Color
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * The phone half of the mailbox contract implemented by relay/src/index.ts:
 * every call is POST {worker}/v1/phone/{action} with {id, secret, ...}; the box
 * only ever keeps sha256(secret). The phone actions are claim / fetch /
 * decide / chat / select / unpair — pair and take belong to the PC.
 *
 * `secret` sent to the relay is HKDF of the pairing master (BoxCrypto), never
 * the master itself; card text, chat lines and decisions travel as encrypted
 * blobs the box cannot read.
 */
object Relay {
    private val JSON = "application/json; charset=utf-8".toMediaType()
    private val client = OkHttpClient.Builder()
        .connectTimeout(8, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .writeTimeout(10, TimeUnit.SECONDS)
        .build()

    /** 403 — the box forgot us (unpaired on the PC, or wrong secret). */
    class Forbidden : Exception("forbidden")

    /** Any other non-2xx from the relay. */
    class Http(val code: Int) : Exception("http $code")

    data class Question(val q: String, val options: List<String>, val multi: Boolean = false)

    data class Card(
        val requestId: String,
        val pillId: String,
        val agent: String,
        val isQuestion: Boolean,
        val title: String,
        val detail: String,
        val options: List<String>,
        val questions: List<Question>,
        /** The "Always allow …" rule the request offered — null when it offered none. */
        val alwaysLabel: String? = null,
        val alwaysDetail: String? = null,
    )

    data class Session(
        val pillId: String,
        val agent: String,
        val color: Int,
        val state: String,
        val statusText: String,
        val stepIndex: Int,
        val stepCount: Int,
    )

    /** name != null → a tool call (compact card), not a chat bubble. */
    data class ChatLine(val isUser: Boolean, val text: String, val name: String? = null)

    /** A CLI session the phone may open and continue (Devin's sessions.db,
     * Claude's ~/.claude/projects/&lt;id&gt;.jsonl). */
    data class ChatSession(
        val id: String,
        val title: String,
        val dir: String,
        val at: Long,
        val agent: String = "devin",
    )

    data class State(
        val sessions: List<Session>,
        val awaiting: Card?,
        val chatTail: List<ChatLine>,
        val chatSessions: List<ChatSession>,
        /** Id of the CLI session the phone is reading, "" = the island's own chat. */
        val chatSel: String,
        /** Transcript tail of the selected session; null when none is selected. */
        val chatTranscript: List<ChatLine>?,
    )

    data class Fetch(
        val paired: Boolean,
        val device: String?,
        val state: State?,
        val card: Card?,
    ) {
        /** The card currently asking — top-level `card` wins, `state.awaiting` is the fallback. */
        val pending: Card? get() = card ?: state?.awaiting
    }

    private fun base(worker: String) = worker.trim().trimEnd('/')

    /** Blocking POST — always call off the main thread. */
    private fun post(worker: String, action: String, body: JSONObject): JSONObject {
        val req = Request.Builder()
            .url("${base(worker)}/v1/phone/$action")
            .post(body.toString().toRequestBody(JSON))
            .build()
        client.newCall(req).execute().use { res ->
            if (res.code == 403) throw Forbidden()
            if (!res.isSuccessful) throw Http(res.code)
            val text = res.body?.string().orEmpty()
            return if (text.isBlank()) JSONObject() else JSONObject(text)
        }
    }

    /** The pair stored on this phone: p.secret is the master, what the relay
     * sees is only its derived bearer. */
    private fun auth(p: Prefs.Pairing) = JSONObject()
        .put("id", p.id)
        .put("secret", BoxCrypto.authBearer(p.secret, p.id) ?: p.secret)

    /** A stored blob decrypted back to its JSON object, or the object itself
     * when it arrived as plaintext (a state pushed by a pre-E2E PC build). */
    private fun unseal(ctx: BoxCrypto.CipherCtx, o: JSONObject?): JSONObject? {
        if (o == null) return null
        if (!o.has("enc")) return o
        val plain = BoxCrypto.open(ctx, o) ?: return null
        return runCatching { JSONObject(String(plain, Charsets.UTF_8)) }.getOrNull()
    }

    fun claim(p: Prefs.Pairing, fcmToken: String) {
        val body = auth(p).put("token", fcmToken).put("name", p.deviceName)
        if (p.deviceId.isNotEmpty()) body.put("device", p.deviceId)
        post(p.worker, "claim", body)
    }

    fun fetch(p: Prefs.Pairing): Fetch {
        val r = post(p.worker, "fetch", auth(p))
        val h2p = BoxCrypto.ciphers(p.secret, p.id)?.second ?: return Fetch(
            paired = r.optBoolean("paired"),
            device = r.optString("device").ifBlank { null },
            state = r.optJSONObject("state")?.let(::parseState),
            card = r.optJSONObject("card")?.let(::parseCard),
        )
        return Fetch(
            paired = r.optBoolean("paired"),
            device = r.optString("device").ifBlank { null },
            state = unseal(h2p, r.optJSONObject("state"))?.let(::parseState),
            card = unseal(h2p, r.optJSONObject("card"))?.let(::parseCard),
        )
    }

    /** One phone → PC message, sealed. `inner` gets the type and the write time. */
    private fun sendSealed(p: Prefs.Pairing, action: String, inner: JSONObject) {
        val (p2h, _) = BoxCrypto.ciphers(p.secret, p.id) ?: throw Forbidden()
        inner.put("at", System.currentTimeMillis())
        val blob = BoxCrypto.seal(p2h, inner.toString().toByteArray(Charsets.UTF_8))
        val body = auth(p)
            .put("n", blob.getString("n"))
            .put("ct", blob.getString("ct"))
        post(p.worker, action, body)
    }

    fun decide(
        p: Prefs.Pairing,
        requestId: String,
        decision: String,
        answers: Map<String, Any>? = null,
        other: List<String> = emptyList(),
    ) {
        val inner = JSONObject()
            .put("type", "decision")
            .put("requestId", requestId)
            .put("decision", decision)
        if (answers != null) {
            inner.put("answers", JSONObject().apply {
                answers.forEach { (k, v) -> put(k, if (v is List<*>) JSONArray(v) else v) }
            })
            // Questions answered in words rather than with a label.
            if (other.isNotEmpty()) inner.put("other", JSONArray(other))
        }
        sendSealed(p, "decide", inner)
    }

    fun chat(p: Prefs.Pairing, text: String, sessionId: String? = null, agent: String? = null) {
        val inner = JSONObject().put("type", "chat").put("text", text)
        if (!sessionId.isNullOrBlank()) {
            inner.put("sessionId", sessionId)
            if (!agent.isNullOrBlank()) inner.put("agent", agent)
        }
        sendSealed(p, "chat", inner)
    }

    /** Tells the PC which CLI session's transcript to push ("" = island chat). */
    fun select(p: Prefs.Pairing, sessionId: String, agent: String? = null) {
        val inner = JSONObject().put("type", "chat_sel").put("sessionId", sessionId)
        if (!agent.isNullOrBlank()) inner.put("agent", agent)
        sendSealed(p, "select", inner)
    }

    fun unpair(p: Prefs.Pairing) {
        post(p.worker, "unpair", auth(p))
    }

    private fun parseCard(o: JSONObject) = Card(
        requestId = o.optString("requestId"),
        pillId = o.optString("pillId"),
        agent = o.optString("agent"),
        isQuestion = o.optString("kind") == "question",
        title = o.optString("title"),
        detail = o.optString("detail"),
        options = o.optJSONArray("options").toStrings(),
        questions = o.optJSONArray("questions").let { arr ->
            (0 until (arr?.length() ?: 0)).map { i ->
                val q = arr!!.getJSONObject(i)
                Question(q.optString("q"), q.optJSONArray("options").toStrings(), q.optBoolean("multi"))
            }
        },
        alwaysLabel = o.optJSONObject("always")?.optString("label")?.ifBlank { null },
        alwaysDetail = o.optJSONObject("always")?.optString("detail")?.ifBlank { null },
    )

    private fun parseState(o: JSONObject): State {
        val sessions = o.optJSONArray("sessions").let { arr ->
            (0 until (arr?.length() ?: 0)).map { i ->
                val s = arr!!.getJSONObject(i)
                Session(
                    pillId = s.optString("pillId"),
                    agent = s.optString("agent"),
                    color = runCatching { Color.parseColor(s.optString("color")) }
                        .getOrDefault(0xFF8C8C8C.toInt()),
                    state = s.optString("state"),
                    statusText = s.optString("statusText"),
                    stepIndex = s.optInt("stepIndex"),
                    stepCount = s.optInt("stepCount"),
                )
            }
        }
        val tail = o.optJSONArray("chatTail").let { arr ->
            (0 until (arr?.length() ?: 0)).map { i ->
                val m = arr!!.getJSONObject(i)
                ChatLine(m.optString("role") == "user", m.optString("text"))
            }
        }
        val chatSessions = o.optJSONArray("chatSessions").let { arr ->
            (0 until (arr?.length() ?: 0)).map { i ->
                val s = arr!!.getJSONObject(i)
                ChatSession(
                    id = s.optString("id"),
                    title = s.optString("title"),
                    dir = s.optString("dir"),
                    at = s.optLong("at"),
                    agent = s.optString("agent").ifBlank { "devin" },
                )
            }
        }
        val transcript = o.optJSONObject("chatTranscript")?.optJSONArray("lines")?.let { arr ->
            (0 until arr.length()).map { i ->
                val m = arr.getJSONObject(i)
                ChatLine(
                    m.optString("role") == "user",
                    m.optString("text"),
                    m.optString("name").ifBlank { null },
                )
            }
        }
        return State(
            sessions = sessions,
            awaiting = o.optJSONObject("awaiting")?.let(::parseCard),
            chatTail = tail,
            chatSessions = chatSessions,
            chatSel = o.optString("chatSel"),
            chatTranscript = transcript,
        )
    }

    private fun JSONArray?.toStrings(): List<String> =
        (0 until (this?.length() ?: 0)).map { this!!.optString(it) }
}
