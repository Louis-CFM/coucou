package fr.louisraille.coucou.phone

import android.app.Application
import android.os.Build
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.google.android.gms.tasks.Tasks
import com.google.firebase.messaging.FirebaseMessaging
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class CoucouViewModel(app: Application) : AndroidViewModel(app) {

    enum class Screen { PAIR, HOME, PICKER, CHAT }

    var screen by mutableStateOf(if (Prefs.load(app) != null) Screen.HOME else Screen.PAIR)
        private set
    /** Agent the PICKER screen lists sessions for ("devin", "claude", …). */
    var pickerAgent by mutableStateOf("devin")
        private set
    var box by mutableStateOf<Relay.Fetch?>(null)
        private set
    /** Non-fatal inline error shown on Home (relay unreachable, etc.). */
    var lineError by mutableStateOf<String?>(null)
        private set
    var pairError by mutableStateOf<String?>(null)
        private set
    var busy by mutableStateOf(false)
        private set
    /** Shown on the settings row. */
    var worker by mutableStateOf(Prefs.load(app)?.worker ?: "")
        private set
    /** Pull-to-refresh spinner. */
    var refreshing by mutableStateOf(false)
        private set
    /** Set when the pending card just got answered locally — shows the sent state until the PC confirms. */
    private var answeredId: String? = null
    private var answeredDecision: String? = null

    fun isAnswered(requestId: String) = requestId == answeredId
    fun sentDecision(requestId: String): String? =
        if (requestId == answeredId) answeredDecision else null

    private var pollJob: Job? = null

    fun navigate(to: Screen) {
        screen = to
    }

    /** Home → an agent's session list. */
    fun openPicker(agent: String) {
        pickerAgent = agent
        screen = Screen.PICKER
    }

    /** The picker's agent dropdown switches which CLI's history it lists. */
    fun pickAgent(agent: String) {
        pickerAgent = agent
    }

    fun onForeground() {
        if (Prefs.load(getApplication()) == null || pollJob?.isActive == true) return
        pollJob = viewModelScope.launch {
            while (isActive) {
                refresh()
                delay(3000)
            }
        }
    }

    fun onBackground() {
        pollJob?.cancel()
        pollJob = null
    }

    /** One-shot fetch for pull-to-refresh — the 3 s poll keeps running anyway. */
    fun refreshNow() {
        if (refreshing) return
        viewModelScope.launch {
            refreshing = true
            try {
                refresh()
            } finally {
                refreshing = false
            }
        }
    }

    private suspend fun refresh() {
        val p = Prefs.load(getApplication()) ?: return
        try {
            val f = withContext(Dispatchers.IO) { Relay.fetch(p) }
            if (f.pending?.requestId != answeredId) {
                answeredId = null
                answeredDecision = null
            }
            box = f
            lineError = null
        } catch (e: Relay.Forbidden) {
            // The box wiped us — drop the pairing and go back to the code screen.
            Prefs.clear(getApplication())
            box = null
            pollJob?.cancel()
            pairError = "This box no longer knows the phone — pair again."
            screen = Screen.PAIR
        } catch (e: Exception) {
            lineError = "Can't reach the relay — ${e.message ?: e.javaClass.simpleName}"
        }
    }

    /** code is `id|secret` or `id|secret|worker` — the QR fallback the PC shows. */
    fun pair(workerIn: String, code: String, nameIn: String) {
        if (busy) return
        val parts = code.trim().split('|').map { it.trim() }
        val workerUrl = (workerIn.ifBlank { parts.getOrNull(2) ?: "" }).trim().trimEnd('/')
        val id = parts.getOrNull(0) ?: ""
        val secret = parts.getOrNull(1) ?: ""
        val name = nameIn.ifBlank { Build.MODEL }
        when {
            workerUrl.isBlank() -> pairError = "Paste the relay URL — or the full code that includes it."
            parts.size < 2 || !id.matches(Regex("[0-9a-fA-F]{24,48}")) ->
                pairError = "The code should look like id|secret|worker."
            !secret.matches(Regex("[0-9a-fA-F]{64}")) ->
                pairError = "The secret in that code isn't 64 hex chars."
            else -> {
                busy = true
                pairError = null
                viewModelScope.launch {
                    val pairing = Prefs.Pairing(workerUrl, id.lowercase(), secret.lowercase(), name)
                    try {
                        val token = withContext(Dispatchers.IO) {
                            Tasks.await(FirebaseMessaging.getInstance().token)
                        }
                        withContext(Dispatchers.IO) { Relay.claim(pairing, token) }
                        Prefs.save(getApplication(), pairing)
                        worker = pairing.worker
                        pairError = null
                        busy = false
                        screen = Screen.HOME
                        refresh()
                        onForeground()
                    } catch (e: Relay.Forbidden) {
                        busy = false
                        pairError = "The relay refused this box (403) — is the PC still showing this code?"
                    } catch (e: Exception) {
                        busy = false
                        pairError = "Couldn't pair — ${e.message ?: "check the URL and the code"}"
                    }
                }
            }
        }
    }

    fun decide(card: Relay.Card, decision: String, answers: Map<String, String>? = null) {
        val p = Prefs.load(getApplication()) ?: return
        answeredId = card.requestId
        answeredDecision = decision
        viewModelScope.launch {
            try {
                withContext(Dispatchers.IO) { Relay.decide(p, card.requestId, decision, answers) }
                refresh()
            } catch (e: Relay.Forbidden) {
                refresh()
            } catch (e: Exception) {
                answeredId = null
                answeredDecision = null
                lineError = "Couldn't send the decision — ${e.message ?: "try again"}"
            }
        }
    }

    /** The Devin session the chat targets, or null for the island's own chat. */
    fun selectedSession(): Relay.ChatSession? =
        box?.state?.let { st -> st.chatSessions.firstOrNull { it.id == st.chatSel } }

    /** Picks the conversation the chat talks to (null = the island's own provider). */
    fun selectSession(session: Relay.ChatSession?) {
        val p = Prefs.load(getApplication()) ?: return
        viewModelScope.launch {
            try {
                withContext(Dispatchers.IO) {
                    Relay.select(p, session?.id ?: "", session?.agent)
                }
                refresh()
            } catch (e: Exception) {
                lineError = "Couldn't open the session — ${e.message ?: "try again"}"
            }
        }
    }

    fun sendChat(text: String) {
        val p = Prefs.load(getApplication()) ?: return
        val t = text.trim()
        if (t.isEmpty()) return
        val session = selectedSession()
        viewModelScope.launch {
            try {
                withContext(Dispatchers.IO) { Relay.chat(p, t, session?.id, session?.agent) }
                refresh()
            } catch (e: Exception) {
                lineError = "Chat not sent — ${e.message ?: "try again"}"
            }
        }
    }

    fun unpair() {
        val p = Prefs.load(getApplication())
        pollJob?.cancel()
        viewModelScope.launch {
            if (p != null) {
                try {
                    withContext(Dispatchers.IO) { Relay.unpair(p) }
                } catch (_: Exception) { /* the box may already be gone — local reset wins */ }
            }
            Prefs.clear(getApplication())
            box = null
            worker = ""
            screen = Screen.PAIR
        }
    }
}
