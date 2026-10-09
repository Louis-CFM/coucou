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
 * decide / chat / unpair — pair and take belong to the PC.
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

    data class Question(val q: String, val options: List<String>)

    data class Card(
        val requestId: String,
        val pillId: String,
        val agent: String,
        val isQuestion: Boolean,
        val title: String,
        val detail: String,
        val options: List<String>,
        val questions: List<Question>,
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

    data class ChatLine(val isUser: Boolean, val text: String)

    data class State(
        val sessions: List<Session>,
        val awaiting: Card?,
        val chatTail: List<ChatLine>,
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

    private fun auth(p: Prefs.Pairing) = JSONObject()
        .put("id", p.id)
        .put("secret", p.secret)

    fun claim(p: Prefs.Pairing, fcmToken: String) {
        post(p.worker, "claim", auth(p).put("token", fcmToken).put("name", p.deviceName))
    }

    fun fetch(p: Prefs.Pairing): Fetch {
        val r = post(p.worker, "fetch", auth(p))
        return Fetch(
            paired = r.optBoolean("paired"),
            device = r.optString("device").ifBlank { null },
            state = r.optJSONObject("state")?.let(::parseState),
            card = r.optJSONObject("card")?.let(::parseCard),
        )
    }

    fun decide(p: Prefs.Pairing, requestId: String, decision: String, answers: Map<String, String>?) {
        val body = auth(p).put("requestId", requestId).put("decision", decision)
        if (answers != null) {
            body.put("answers", JSONObject().apply { answers.forEach { (k, v) -> put(k, v) } })
        }
        post(p.worker, "decide", body)
    }

    fun chat(p: Prefs.Pairing, text: String) {
        post(p.worker, "chat", auth(p).put("text", text))
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
                Question(q.optString("q"), q.optJSONArray("options").toStrings())
            }
        },
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
        return State(
            sessions = sessions,
            awaiting = o.optJSONObject("awaiting")?.let(::parseCard),
            chatTail = tail,
        )
    }

    private fun JSONArray?.toStrings(): List<String> =
        (0 until (this?.length() ?: 0)).map { this!!.optString(it) }
}
