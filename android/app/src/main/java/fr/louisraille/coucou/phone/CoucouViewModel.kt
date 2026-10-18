package fr.louisraille.coucou.phone

import android.app.Application
import android.os.Build
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.viewModelScope
import com.google.android.gms.tasks.Tasks
import com.google.firebase.messaging.FirebaseMessaging
import fr.louisraille.coucou.phone.outfit.Wardrobe
import fr.louisraille.coucou.phone.widget.CoucouWidget
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class CoucouViewModel(app: Application, private val saved: SavedStateHandle) : AndroidViewModel(app) {

    enum class Screen { PAIR, HOME, PICKER, CHAT, SETTINGS }

    var screen by mutableStateOf(initialScreen(app))
        private set
    /** Agent the PICKER screen lists sessions for ("devin", "claude", …). */
    var pickerAgent by mutableStateOf(saved.get<String>(K_AGENT) ?: "devin")
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
    /** Mochi's wardrobe pick: "auto" (the season decides) or an outfit id. */
    var outfitSel by mutableStateOf(Wardrobe.parse(Prefs.outfit(app)))
        private set

    fun setOutfit(selection: String) {
        outfitSel = Wardrobe.parse(selection)
        Prefs.setOutfit(getApplication(), outfitSel)
    }
    /** Set when the pending card just got answered locally — shows the sent state until the PC confirms. */
    private var answeredId: String? = null
    private var answeredDecision: String? = null

    /** pillId → last state we announced; a change into a terminal state pings quietly. */
    private val announced = mutableMapOf<String, String>()
    /** The pending card we last saw — a new id gets Mochi's sound in-app. */
    private var lastCardId: String? = null

    fun isAnswered(requestId: String) = requestId == answeredId
    fun sentDecision(requestId: String): String? =
        if (requestId == answeredId) answeredDecision else null

    private var pollJob: Job? = null

    private fun initialScreen(app: Application): Screen {
        val paired = Prefs.load(app) != null
        val restored = saved.get<String>(K_SCREEN)?.let { runCatching { Screen.valueOf(it) }.getOrNull() }
        return when {
            !paired -> Screen.PAIR
            restored != null && restored != Screen.PAIR -> restored
            else -> Screen.HOME
        }
    }

    private fun show(to: Screen) {
        screen = to
        saved[K_SCREEN] = to.name
    }

    private companion object {
        const val K_SCREEN = "screen"
        const val K_AGENT = "pickerAgent"
    }

    /** User-facing line/pair errors live in resources — the app may be localized. */
    private fun str(id: Int, vararg args: Any): String =
        getApplication<Application>().getString(id, *args)

    fun navigate(to: Screen) {
        show(to)
    }

    /** Home → an agent's session list. */
    fun openPicker(agent: String) {
        pickerAgent = agent
        saved[K_AGENT] = agent
        show(Screen.PICKER)
    }

    /** The picker's agent dropdown switches which CLI's history it lists. */
    fun pickAgent(agent: String) {
        pickerAgent = agent
        saved[K_AGENT] = agent
    }

    fun onForeground() {
        val p = Prefs.load(getApplication()) ?: return
        // Coucou is on screen: the quiet notices in the shade are redundant.
        Notifier.cancelAllStatus(getApplication())
        syncToken(p)
        if (pollJob?.isActive == true) return
        pollJob = viewModelScope.launch {
            var failures = 0
            while (isActive) {
                failures = if (refresh()) 0 else (failures + 1).coerceAtMost(4)
                // A relay that is not answering gets a pause, not a hammer:
                // 3 s healthy, doubling to under a minute while it stays down.
                delay(3000L shl failures)
            }
        }
    }

    /**
     * Claims the box again when FCM rotated this phone's token since the last
     * claim that got through: a refresh the service could not deliver (offline,
     * relay down) is caught up the next time the app comes forward.
     */
    private fun syncToken(p: Prefs.Pairing) {
        viewModelScope.launch {
            try {
                val token = withContext(Dispatchers.IO) { Tasks.await(FirebaseMessaging.getInstance().token) }
                if (!TokenSync.shouldClaim(Prefs.claimedToken(getApplication()), token)) return@launch
                withContext(Dispatchers.IO) { Relay.claim(p, token) }
                Prefs.setClaimedToken(getApplication(), token)
            } catch (e: Relay.Http) {
                if (e.code == 409) lineError = str(R.string.error_box_taken)
            } catch (_: Exception) {
                // Offline or no Play services: tried again next time the app comes forward.
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

    /** @return false when the relay could not be reached — the poll backs off. */
    private suspend fun refresh(): Boolean {
        val p = Prefs.load(getApplication()) ?: return true
        try {
            val f = withContext(Dispatchers.IO) { Relay.fetch(p) }
            if (f.pending?.requestId != answeredId) {
                answeredId = null
                answeredDecision = null
            }
            // A card answered on the PC or past its time leaves no dead
            // Allow/Deny notification — the push path does the same.
            if (f.pending == null) Notifier.cancelCard(getApplication())
            announce(f)
            Notifier.updateLive(getApplication(), f.state?.sessions.orEmpty())
            CoucouWidget.push(getApplication(), f.state?.sessions.orEmpty())
            box = f
            lineError = null
            return true
        } catch (e: Relay.Forbidden) {
            // The box wiped us — drop the pairing and go back to the code screen.
            Prefs.clear(getApplication())
            Notifier.cancelLive(getApplication())
            box = null
            pollJob?.cancel()
            pairError = str(R.string.error_box_unknown)
            show(Screen.PAIR)
        } catch (e: Exception) {
            lineError = str(R.string.error_relay, e.message ?: e.javaClass.simpleName)
            return false
        }
        return true
    }

    /**
     * Quiet pings for what changed: a session reaching finished/error/ratelimit
     * posts to the updates channel (questions and approvals are the loud card),
     * and a fresh card plays Mochi's sound in-app. Only transitions announce —
     * a state we already saw stays silent.
     */
    private fun announce(f: Relay.Fetch) {
        val app = getApplication<Application>()
        val sessions = f.state?.sessions.orEmpty()
        // A pill that left the state leaves the map too — its next appearance
        // is a fresh session, not a transition to announce.
        announced.keys.retainAll(sessions.mapTo(HashSet()) { it.pillId })
        for (s in sessions) {
            val prev = announced[s.pillId]
            announced[s.pillId] = s.state
            if (prev != null && prev != s.state && s.state in setOf("finished", "error", "ratelimit")) {
                Notifier.showStatus(app, s)
            }
        }
        val cardId = f.pending?.requestId
        if (cardId != null && cardId != lastCardId) {
            Sounds.play(app, if (f.pending!!.isQuestion) R.raw.question else R.raw.approval)
        }
        lastCardId = cardId
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
            workerUrl.isBlank() -> pairError = str(R.string.pair_error_no_url)
            // Every request carries the pairing secret — it must not fly over
            // plain HTTP (except local development).
            !workerUrl.lowercase().let {
                it.startsWith("https://") || it.startsWith("http://127.0.0.1") || it.startsWith("http://localhost")
            } -> pairError = str(R.string.pair_error_https)
            parts.size < 2 || !id.matches(Regex("[0-9a-fA-F]{24,48}")) ->
                pairError = str(R.string.pair_error_code)
            !secret.matches(Regex("[0-9a-fA-F]{64}")) ->
                pairError = str(R.string.pair_error_secret)
            else -> {
                busy = true
                pairError = null
                viewModelScope.launch {
                    val pairing = Prefs.Pairing(workerUrl, id.lowercase(), secret.lowercase(), name, DeviceId.new())
                    try {
                        val token = withContext(Dispatchers.IO) {
                            Tasks.await(FirebaseMessaging.getInstance().token)
                        }
                        withContext(Dispatchers.IO) { Relay.claim(pairing, token) }
                        Prefs.save(getApplication(), pairing)
                        Prefs.setClaimedToken(getApplication(), token)
                        worker = pairing.worker
                        pairError = null
                        busy = false
                        show(Screen.HOME)
                        refresh()
                        onForeground()
                    } catch (e: Relay.Forbidden) {
                        busy = false
                        pairError = str(R.string.pair_error_refused)
                    } catch (e: Exception) {
                        busy = false
                        pairError = str(R.string.pair_error_failed, e.message ?: str(R.string.pair_error_check))
                    }
                }
            }
        }
    }

    fun decide(
        card: Relay.Card,
        decision: String,
        answers: Map<String, Any>? = null,
        other: List<String> = emptyList(),
    ) {
        val p = Prefs.load(getApplication()) ?: return
        answeredId = card.requestId
        answeredDecision = decision
        viewModelScope.launch {
            try {
                withContext(Dispatchers.IO) { Relay.decide(p, card.requestId, decision, answers, other) }
                refresh()
            } catch (e: Relay.Forbidden) {
                refresh()
            } catch (e: Exception) {
                answeredId = null
                answeredDecision = null
                lineError = str(R.string.error_decision, e.message ?: str(R.string.error_try_again))
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
                lineError = str(R.string.error_session, e.message ?: str(R.string.error_try_again))
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
                lineError = str(R.string.error_chat, e.message ?: str(R.string.error_try_again))
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
            Notifier.cancelLive(getApplication())
            Notifier.cancelAllCards(getApplication())
            CoucouWidget.clear(getApplication())
            box = null
            worker = ""
            show(Screen.PAIR)
        }
    }
}
