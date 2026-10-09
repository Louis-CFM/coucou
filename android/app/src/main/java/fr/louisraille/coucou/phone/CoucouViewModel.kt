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

    enum class Screen { PAIR, HOME, CHAT }

    var screen by mutableStateOf(if (Prefs.load(app) != null) Screen.HOME else Screen.PAIR)
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
    /** Set when the pending card just got answered locally — hides it until the PC confirms. */
    private var answeredId: String? = null

    fun isAnswered(requestId: String) = requestId == answeredId

    private var pollJob: Job? = null

    fun navigate(to: Screen) {
        screen = to
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

    private suspend fun refresh() {
        val p = Prefs.load(getApplication()) ?: return
        try {
            val f = withContext(Dispatchers.IO) { Relay.fetch(p) }
            if (f.pending?.requestId != answeredId) answeredId = null
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
        viewModelScope.launch {
            try {
                withContext(Dispatchers.IO) { Relay.decide(p, card.requestId, decision, answers) }
                refresh()
            } catch (e: Relay.Forbidden) {
                refresh()
            } catch (e: Exception) {
                answeredId = null
                lineError = "Couldn't send the decision — ${e.message ?: "try again"}"
            }
        }
    }

    fun sendChat(text: String) {
        val p = Prefs.load(getApplication()) ?: return
        val t = text.trim()
        if (t.isEmpty()) return
        viewModelScope.launch {
            try {
                withContext(Dispatchers.IO) { Relay.chat(p, t) }
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
