package com.coucou.android.app

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.PowerManager
import android.os.Looper
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.coucou.android.R
import com.coucou.android.core.ChatTab
import com.coucou.android.core.ChatTabState
import com.coucou.android.core.Decision
import com.coucou.android.core.DecisionLog
import com.coucou.android.core.KeyValueStore
import com.coucou.android.core.IslandPlan
import com.coucou.android.core.OverlayChoice
import com.coucou.android.core.StatusPolicy
import com.coucou.android.core.UserSettings
import com.coucou.android.core.OverlayPolicy
import com.coucou.android.core.WishStore
import com.coucou.android.core.Pills
import com.coucou.android.ui.IslandOverlay
import com.coucou.android.link.Protocol
import com.coucou.android.link.ChatModel
import com.coucou.android.core.PairingScan
import com.coucou.android.core.ScanDecision
import com.coucou.android.core.ChatHistory
import com.coucou.android.core.ChatModels
import com.coucou.android.core.ChatSession
import com.coucou.android.link.AddressFinder
import com.coucou.android.link.ApprovalRequest
import com.coucou.android.link.QuestionRequest
import com.coucou.android.link.Cancelable
import com.coucou.android.link.Discovery
import com.coucou.android.link.DiscoveryPolicy
import com.coucou.android.link.DiscoveryState
import com.coucou.android.link.PinnedProbe
import com.coucou.android.link.DemoLink
import com.coucou.android.link.Connector
import com.coucou.android.link.DesktopLink
import com.coucou.android.link.PinnedTls
import com.coucou.android.link.LinkClient
import com.coucou.android.link.LinkListener
import com.coucou.android.link.LinkState
import com.coucou.android.link.BatteryHint
import com.coucou.android.link.DiagResult
import com.coucou.android.link.DiagStep
import com.coucou.android.link.Diagnostics
import com.coucou.android.link.Found
import com.coucou.android.link.LanDiagnostics
import com.coucou.android.link.LinkHealth
import com.coucou.android.link.LostReason
import com.coucou.android.link.PairingPayload
import com.coucou.android.link.ReconnectPolicy
import com.coucou.android.link.Wake
import com.coucou.android.link.SessionInfo
import com.coucou.android.sound.SoundPlayer
import com.coucou.android.mochi.BotState

enum class Mode { NONE, DEMO, PAIRED }

/** The one place the UI, the service and the notification actions share. Created by [CoucouApp]. */
class AppModel(private val context: Context) : LinkListener {
    private val main = Handler(Looper.getMainLooper())
    private val store = SecureStore(context)
    val sounds = SoundPlayer(context)
    val notifier = Notifications(context)

    /** Set only by LaunchActivity (not exported), read by MainActivity: see [com.coucou.android.core.PendingLaunch]. */
    val launch = com.coucou.android.core.PendingLaunch()

    /** Text shared to Coucou from another app, waiting to be put in the chat box (see [com.coucou.android.core.ShareDraft]). */
    val shareDraft = com.coucou.android.core.ShareDraft()

    /** Changes with every share, so a chat screen that is already open notices there is a new draft. */
    var shareVersion by mutableStateOf(0); private set

    /** Keeps [text] (cleaned) as the draft for the chat box. Called by the share target only. */
    fun offerShare(text: String?) {
        shareDraft.offer(text)
        shareVersion++
    }

    /** Agent tasks finished today, for the Today widget. Kept on this phone only (see [TodayStore]). */
    private val todayCounter = com.coucou.android.core.TodayCounter(TodayStore(context))

    var mode by mutableStateOf(Mode.NONE); private set
    var linkState by mutableStateOf(LinkState.DISCONNECTED); private set
    var desktopName by mutableStateOf<String?>(null); private set
    var sessions by mutableStateOf<List<SessionInfo>>(emptyList()); private set
    var approvals by mutableStateOf<List<ApprovalRequest>>(emptyList()); private set
    /** Questions Claude Code asks that this phone may answer (only with the `answers` capability); kept in memory, never written. */
    var questions by mutableStateOf<List<QuestionRequest>>(emptyList()); private set
    var message by mutableStateOf<String?>(null)

    // ── Finding the computer again when its address changed (docs/ANDROID_LINK.md, "Finding the computer") ──
    /** What the search for the computer is doing, for the status line and the hint. */
    var discovery by mutableStateOf(DiscoveryState.IDLE); private set
    /** The pairing the running link uses (with the address in force); the token stays in memory only as long as the link does. */
    @Volatile private var currentPairing: PairingPayload? = null
    private val probeExecutor = java.util.concurrent.Executors.newSingleThreadExecutor { r -> Thread(r, "coucou-probe").apply { isDaemon = true } }
    /** Which way the link reaches the computer now (null until connected), and why the relay failed, if it did. */
    var route by mutableStateOf<com.coucou.android.link.Route?>(null); private set
    var relayIssue by mutableStateOf(com.coucou.android.link.RelayIssue.NONE); private set
    private val transport = com.coucou.android.link.TransportPolicy({ currentPairing?.relay != null && settings.useRelay })
    @Volatile private var fallback: com.coucou.android.link.FallbackConnector? = null
    @Volatile private var relayConnector: com.coucou.android.link.RelayConnector? = null

    /** Whether the pairing in force includes a relay (shown in Settings > Away from home Wi-Fi). */
    val hasRelay: Boolean get() = currentPairing?.relay != null
    val relayHost: String? get() = currentPairing?.relay?.relayUrl()?.host

    private val netWatch = NetworkWatch(context, { up -> main.post { onNetworkChanged(up) } }, { main.post { onWake(Wake.NEW_NETWORK) } })
    private val finder = AddressFinder(
        source = NsdDiscovery(context), probe = PinnedProbe,
        pairing = { currentPairing }, allowed = { mayDiscover() },
        onAddress = { host, port -> main.post { onAddressFound(host, port) } },
        onState = { st -> main.post { discovery = st } },
        scheduler = { delay, task -> val r = Runnable { task() }; main.postDelayed(r, delay); Cancelable { main.removeCallbacks(r) } },
        runner = { task -> probeExecutor.execute { task() } },
    )

    private fun mayDiscover() = DiscoveryPolicy.mayDiscover(
        paired = currentPairing != null, demo = mode == Mode.DEMO, wifiUp = netWatch.wifiUp, linkConnected = linkState == LinkState.CONNECTED,
    )

    private val prefs = context.getSharedPreferences("coucou_ui", Context.MODE_PRIVATE)
    private val kv = object : KeyValueStore {
        override fun getBoolean(key: String, default: Boolean) = prefs.getBoolean(key, default)
        override fun getInt(key: String, default: Int) = prefs.getInt(key, default)
        override fun getFloat(key: String, default: Float) = prefs.getFloat(key, default)
        override fun getString(key: String, default: String) = prefs.getString(key, default) ?: default
        override fun put(key: String, value: Any) {
            prefs.edit().apply {
                when (value) {
                    is Boolean -> putBoolean(key, value)
                    is Int -> putInt(key, value)
                    is Float -> putFloat(key, value)
                    is String -> putString(key, value)
                }
            }.apply()
        }
    }

    /** The language the surfaces (Widgets, the ongoing notification) were last drawn in. */
    private var surfacesLanguage: String? = null

    /** The app's language is [tag] now: what the Widgets and the notification say is written again in it (once per change). */
    fun languageChanged(tag: String) {
        if (surfacesLanguage == tag) return
        val first = surfacesLanguage == null
        surfacesLanguage = tag
        if (first) return // the first look at it, at start: nothing was drawn in another language
        notifier.forgetOngoing()
        WidgetHub.refreshAll(context)
        pushGlance()
    }

    /** What the user chose in Settings (sound, notices, quiet hours). */
    var settings by mutableStateOf(UserSettings.load(kv)); private set

    fun updateSettings(next: UserSettings) {
        val relayChanged = next.useRelay != settings.useRelay
        settings = next
        UserSettings.save(kv, next)
        applySound()
        notifier.applyApprovalSettings(settings.vibration, settings.keepScreenOff)
        com.coucou.android.core.MotionState.choice = settings.motion
        // Switching the relay on or off rebuilds the connection with the right routes.
        if (relayChanged) currentPairing?.let { restartLink(it) }
    }

    private fun applySound() {
        sounds.enabled = settings.soundOn
        sounds.volume = settings.volume
    }

    init {
        applySound()
        notifier.applyApprovalSettings(settings.vibration, settings.keepScreenOff)
        com.coucou.android.core.MotionState.choice = settings.motion
    }

    /** What the computer says Mochi wears ("auto" or an outfit); the last one it told, kept for when it is away. */
    var computerOutfit by mutableStateOf(com.coucou.android.mochi.outfit.Wardrobe.parse(kv.getString("computer_outfit", "")))
        private set

    /** The selection in force: the phone's own choice, or the computer's when the phone follows it. */
    val outfitSelection: String
        get() = com.coucou.android.mochi.outfit.Wardrobe.choose(settings.outfit, computerOutfit)

    /** What Mochi wears today ("auto" resolved with the phone's calendar). */
    fun dress(today: java.time.LocalDate = java.time.LocalDate.now()): com.coucou.android.mochi.outfit.Outfit =
        com.coucou.android.mochi.outfit.Wardrobe.resolve(outfitSelection, today)

    /** The phone's own list of decisions. Never sent anywhere. */
    private val decisionLog = DecisionLog(kv)
    var decisions by mutableStateOf(decisionLog.all()); private set

    fun clearDecisions() {
        decisionLog.clear()
        decisions = emptyList()
    }

    fun recordDecision(d: Decision) {
        decisionLog.add(d)
        decisions = decisionLog.all()
    }

    // ── Chat through the computer (docs/ANDROID_LINK.md). The UI comes in the next step. ──────────

    private val chatHistory = ChatHistory(ChatFile(java.io.File(context.filesDir, "chat-history.json")))
    private val chatSession = ChatSession(chatHistory.load())

    /** What the user reads: this phone's own copy, kept in a private file. */
    var chatMessages by mutableStateOf(chatSession.messages); private set

    /** An answer is being waited for. */
    var chatBusy by mutableStateOf(false); private set

    /** The computer offers chat to this phone right now (its switch is on and we are connected). */
    var chatOffered by mutableStateOf(false); private set

    /** The models the user allowed on the computer; the keys never leave it. */
    var chatModels by mutableStateOf<List<ChatModel>>(emptyList()); private set

    var chatModel by mutableStateOf<String?>(prefs.getString("chat_model", null)); private set

    /** The computer offers session details (steps, last message, project folder, colour) to this phone. */
    var detailsOffered by mutableStateOf(false); private set
    /** The computer lists the files an agent changed and can send their lines (its switch is on). */
    var diffsOffered by mutableStateOf(false); private set
    /** The Claude and Codex plan usage the computer sent (its switch is on); null: nothing to show. */
    var usage by mutableStateOf<com.coucou.android.link.UsageSnapshot?>(null); private set

    /** Last week's recap the computer sent (its switch is on); null: nothing to show. Held in memory only, never stored. */
    var recap by mutableStateOf<com.coucou.android.link.Recap?>(null); private set
    /** The read-only service cards the user allowed on the computer; empty: none. */
    var services by mutableStateOf<List<com.coucou.android.link.ServiceCard>>(emptyList()); private set

    /** What the Chat tab shows: not paired, not reachable, chat off on the computer, no model allowed, or ready. */
    val chatTabState: ChatTabState get() = ChatTab.state(
        paired = mode == Mode.PAIRED, connected = linkState == LinkState.CONNECTED, offered = chatOffered, modelCount = chatModels.size,
    )

    /** Chat is usable: offered, at least one model allowed, connected. */
    val chatAvailable: Boolean get() = chatOffered && chatModels.isNotEmpty() && linkState == LinkState.CONNECTED

    private fun chatChanged(save: Boolean) {
        chatMessages = chatSession.messages
        chatBusy = chatSession.running != null
        if (save) chatHistory.save(chatSession.messages)
    }

    fun chatSelect(id: String) {
        if (chatModels.any { it.id == id }) {
            chatModel = id
            prefs.edit().putString("chat_model", id).apply()
        }
    }

    /** Asks the computer again which models are allowed (when the Chat screen opens). */
    fun chatRefreshModels() { link?.chatModels() }

    /** Null when sent, else why not (for a message under the box). */
    fun chatSend(text: String): ChatSession.Refusal? {
        val sent = chatSession.send(text, chatModel, connected = chatAvailable)
        return when (sent) {
            is ChatSession.Sent.No -> sent.why
            is ChatSession.Sent.Ok -> {
                chatChanged(save = true)
                if (link?.chatSend(sent.msg.id, sent.msg.model, sent.msg.text) != true) {
                    chatSession.onDisconnected()
                    chatChanged(save = true)
                }
                null
            }
        }
    }

    fun chatCancel() {
        chatSession.cancel()?.let { link?.chatCancel(it) }
        chatChanged(save = true)
    }

    /** Clear: forgets the history here and on the computer. */
    fun chatClear() {
        chatSession.cancel()?.let { link?.chatCancel(it) }
        chatSession.clear()
        chatHistory.clear()
        link?.chatReset()
        chatChanged(save = false)
    }

    private fun chatLinkLost() {
        detailsOffered = false
        chatOffered = false
        chatModels = emptyList()
        if (chatSession.running != null) {
            chatSession.onDisconnected()
            chatChanged(save = true)
        }
    }

    private val choice = OverlayChoice(object : WishStore {
        override fun read() = prefs.getBoolean("overlay", false)
        // commit(): a tiny file, and it must survive the process being killed while the user is in Settings.
        override fun write(on: Boolean) { prefs.edit().putBoolean("overlay", on).commit() }
    })

    /** The user's wish for the pill over other apps (off until they turn it on). Saved when they tap. */
    var overlayWished by mutableStateOf(choice.wished); private set

    /** The system permission "display over other apps", re-read when the app comes to the front. */
    var overlayPermission by mutableStateOf(false); private set

    /** The app is on screen: it shows everything itself, so the pill stays away. */
    var inForeground = false
        set(value) {
            field = value
            if (value) {
                overlay.hide()
                notifier.cancelAllStatus()
            } else {
                refreshIsland() // the user left the app: an agent at work shows on the island at once
            }
        }

    private val overlay = IslandOverlay(
        context, { android.os.SystemClock.elapsedRealtimeNanos() / 1e6 },
        onAllow = { notifier.openAllow(it) },
        onDeny = { decide(it, allow = false) },
        onOpen = { notifier.openApp() },
    )

    fun overlayPermitted() = overlay.permitted()

    /** What the switch shows: wished and allowed by the system. */
    val overlayOn: Boolean get() = overlayWished && overlayPermission

    fun refreshOverlayPermission() { overlayPermission = overlay.permitted() }

    /** The user tapped the switch: remember the choice right now (see [OverlayChoice]). */
    fun useOverlay(on: Boolean) {
        choice.choose(on)
        overlayWished = on
        refreshOverlayPermission()
        refreshIsland()
    }

    private fun islandAllowed(): Boolean {
        val connected = mode != Mode.PAIRED || linkState == LinkState.CONNECTED
        val why = OverlayPolicy.blocker(choice.wished, overlay.permitted(), inForeground)
            ?: if (!connected) "not connected to a computer" else null
        if (why != null) Log.d("CoucouOverlay", "no island: $why")
        return why == null
    }

    /**
     * What the island shows right now (an agent at work, a question, a request), from the current
     * sessions and requests. When it may not show at all it is removed completely.
     */
    /** What the notification, the widget and the tile say right now. */
    fun glance(): com.coucou.android.core.Glance = com.coucou.android.core.GlanceBuilder.build(
        mode != Mode.NONE || isPaired, linkState, desktopName, sessions, approvals.size, this::agentName,
    )

    /** What the Widgets draw now: the glance, the sessions, the plan usage the computer sent and today's finished tasks. */
    fun widgetContent(g: com.coucou.android.core.Glance = glance()): com.coucou.android.core.WidgetContent =
        com.coucou.android.core.WidgetData.build(g, sessions, this::agentName, usage, todayCounter.count(), System.currentTimeMillis())

    /** The small surfaces follow every change of sessions, requests and link; none of them runs a timer. */
    private fun pushGlance() {
        val g = glance()
        notifier.updateOngoing(this, g)
        GlanceWidget.update(context, g)
        WidgetHub.update(context, widgetContent(g))
        GlanceTile.requestUpdate(context)
    }

    private fun refreshIsland() {
        pushGlance()
        if (!islandAllowed()) {
            overlay.hide()
            return
        }
        overlay.setActive(IslandPlan.active(sessions, approvals, allowed = true, this::agentName))
    }

    /**
     * Allow was tapped on a notification before the link was back (the app had been closed): the
     * desktop offers the request again as soon as it reconnects, and the biometric prompt opens then.
     */
    var wantAllow by mutableStateOf<String?>(null)

    private val expiry = HashMap<String, Runnable>()
    private var link: DesktopLink? = null
    private val lastState = HashMap<String, BotState>()

    /** The name the user knows the agent by: the session's own name, else the pill catalog. */
    fun agentName(pillId: String): String =
        sessions.firstOrNull { it.pillId == pillId }?.agent?.takeIf { it.isNotBlank() } ?: Pills.byId(pillId)?.name ?: com.coucou.android.core.Texts.t("agent_an_title", "An agent")

    val isPaired get() = store.loadPairing() != null

    /** Called at launch and by the service: reconnects to the stored desktop, if any. */
    fun resume() {
        if (mode == Mode.DEMO || link != null) return
        val p = store.loadPairing() ?: return
        connect(p)
    }

    /**
     * A pairing link waiting for the user's OK: read from the QR code, or opened from the camera app. Held in
     * memory only while the question is on screen; it is never logged and goes nowhere but into [pair].
     */
    var pairRequest by mutableStateOf<String?>(null); private set

    /** True if [text] is a Coucou pairing link (the user is now asked to confirm); false for any other text. */
    fun requestPairing(text: String?): Boolean {
        val d = PairingScan.decide(text)
        if (d !is ScanDecision.Pairing) return false
        pairRequest = d.link
        return true
    }

    fun confirmPairing() {
        val link = pairRequest ?: return
        pairRequest = null
        pair(link)
    }

    fun cancelPairing() { pairRequest = null }

    fun pair(text: String): Boolean {
        val p = PairingPayload.parse(text)
        if (p == null) { message = context.getString(R.string.msg_bad_link); return false }
        stopLink()
        store.savePairing(p)
        connect(p)
        return true
    }

    private fun connect(p: PairingPayload) {
        mode = Mode.PAIRED
        desktopName = p.desktopName.ifBlank { p.host }
        currentPairing = p
        link = newLink(p).also { it.start() }
        netWatch.start()
        screenWatch.start()
        KeepAliveAlarm.arm(context)
        LinkService.start(context)
    }

    /** The saved address is replaced; the token and the pinned certificate are the same. The link restarts at once. */
    private fun useAddress(host: String, port: Int) {
        val p = currentPairing ?: return
        val q = Discovery.withAddress(p, host, port)
        store.savePairing(q)
        currentPairing = q
        restartLink(q)
    }

    /** A link for this pairing: the direct connection, and the relay behind it when the pairing has one and the user allows it. */
    private fun newLink(p: PairingPayload): LinkClient {
        val lan = PinnedTls.connector(p)
        val relay = p.relay
        fallback?.stop()
        val connector: Connector = if (relay != null && settings.useRelay) {
            val rc = com.coucou.android.link.RelayConnector(relay)
            relayConnector = rc
            com.coucou.android.link.FallbackConnector(lan, rc, transport, onRoute = { r -> main.post { route = r } }).also { fallback = it }
        } else {
            relayConnector = null
            fallback = null
            route = null
            lan
        }
        return LinkClient(p, Build.MODEL ?: "Android", this, connector = connector)
    }

    private fun restartLink(p: PairingPayload) {
        link?.stop()
        link = newLink(p).also { it.start() }
    }

    /** A computer matching the paired fingerprint answered with the pinned certificate (checked by a bare TLS handshake). */
    private fun onAddressFound(host: String, port: Int) {
        if (mode != Mode.PAIRED || currentPairing == null) return
        Log.d("CoucouDiscovery", "address updated")
        useAddress(host, port)
    }

    // ── Keeping the link alive while the phone sleeps (docs/ANDROID_LINK.md, "Keeping the link alive") ──

    /** What happened to the link: when it was lost and why, and how often the screen had been off when it was. */
    /** Whether the phone is on Wi-Fi now, for the sentence that names why the link was lost. */
    val wifiUp: Boolean get() = netWatch.wifiUp

    var health by mutableStateOf(LinkHealth(dropsWhileScreenOff = kv.getInt("link_drops_off", 0))); private set
    /** The screen was off at some point since the link last came up. */
    @Volatile private var screenWasOff = false
    private val power = context.getSystemService(PowerManager::class.java)
    private val screenWatch = ScreenWatch(context) { on -> main.post { if (on) onWake(Wake.SCREEN_ON) else screenWasOff = true } }
    private var batteryTick by mutableStateOf(0)
    var batterySnoozedAt by mutableStateOf(kv.getString("battery_snoozed_at", "").toLongOrNull()); private set

    /** The screen turned on, a network appeared, or the alarm fired: look at the link now (rules in [ReconnectPolicy]). */
    private fun onWake(event: Wake) {
        val relay = currentPairing?.relay != null && settings.useRelay
        when (ReconnectPolicy.decide(event, mode == Mode.PAIRED, linkState == LinkState.CONNECTED, netWatch.wifiUp, relay)) {
            ReconnectPolicy.Action.RETRY_NOW -> link?.retryNow()
            ReconnectPolicy.Action.CHECK_NOW -> link?.checkNow()
            ReconnectPolicy.Action.NONE -> {}
        }
    }

    /** The periodic alarm. If Android had stopped the app, this is also what brings the link back (the pairing is stored). */
    fun keepAliveTick() {
        if (mode == Mode.NONE) resume()
        if (mode != Mode.PAIRED) return
        onWake(Wake.ALARM)
        KeepAliveAlarm.arm(context)
    }

    /** Suggest the battery setting only when the link ended on its own after the screen had been off and the app is still restricted. */
    val batteryHintVisible: Boolean get() {
        batteryTick // read so a change of the setting redraws Home
        return BatteryHint.shouldShow(mode == Mode.PAIRED, health, power?.isIgnoringBatteryOptimizations(context.packageName) == true, batterySnoozedAt, System.currentTimeMillis())
    }
    val batterySteps: List<String> get() = BatteryHint.steps(BatteryHint.isSamsung(Build.MANUFACTURER))
    /** The user may have changed the setting in Android's screen: look again when the app comes back. */
    fun refreshBattery() { batteryTick++ }
    fun snoozeBatteryHint() {
        val now = System.currentTimeMillis()
        kv.put("battery_snoozed_at", now.toString())
        batterySnoozedAt = now
    }

    // ── "Can't connect?" ──
    var diagResults by mutableStateOf<List<Pair<DiagStep, DiagResult>>>(emptyList()); private set
    var diagRunning by mutableStateOf(false); private set

    fun runDiagnostics() {
        val p = currentPairing ?: return
        if (diagRunning) return
        diagRunning = true
        diagResults = emptyList()
        probeExecutor.execute {
            val env = LanDiagnostics(
                p, wifiUp = { netWatch.isWifiUp() }, onCellular = { netWatch.isCellular() }, discover = { browse(4_000) },
                relayCheck = p.relay?.let { r -> { LanDiagnostics.relayReachable(r) } },
            )
            Diagnostics.run(env) { step, result -> main.post { diagResults = diagResults + (step to result) } }
            main.post { diagRunning = false }
        }
    }

    /** Listens for the computer's announcement for [ms] on a separate browser, so the link's own search is not disturbed. */
    private fun browse(ms: Long): List<Found> {
        val seen = java.util.concurrent.CopyOnWriteArrayList<Found>()
        val source = NsdDiscovery(context)
        source.start { seen.add(it) }
        try { Thread.sleep(ms) } finally { source.stop() }
        return seen.toList()
    }

    /** The text the user can copy: the checks and what they found, with no code, fingerprint, name or full address. */
    fun diagnosticsReport(): String {
        val p = currentPairing
        val version = runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull() ?: "?"
        val via = when {
            linkState != LinkState.CONNECTED -> "not connected"
            route == com.coucou.android.link.Route.RELAY -> "the relay"
            else -> "the direct link"
        }
        return Diagnostics.report(version, Build.VERSION.RELEASE, "${Build.MANUFACTURER} ${Build.MODEL}", diagResults, p?.let { Diagnostics.maskHost(it.host) } ?: "none", via)
    }

    private fun onNetworkChanged(wifiUp: Boolean) {
        if (mode != Mode.PAIRED) return
        if (!wifiUp) { finder.stop(); return } // no Wi-Fi: nothing to scan
        fallback?.networkChanged() // on the relay: is the computer on this network? Then move back to the direct link
        link?.retryNow() // do not wait out the backoff on a new network
        if (mayDiscover()) finder.networkChanged()
    }

    /**
     * "Enter address manually": a host or host:port typed by the user. The pairing, the token and the pinned
     * certificate are unchanged, so a wrong or hostile address still cannot get past the certificate check.
     */
    fun setAddress(text: String): Boolean {
        val (host, port) = Discovery.parseAddress(text) ?: return false
        if (currentPairing == null) return false
        useAddress(host, port)
        return true
    }

    fun startDemo() {
        stopLink()
        mode = Mode.DEMO
        link = DemoLink(this).also { it.start() }
    }

    /** Forgets the desktop: closes the link and deletes the stored secret. */
    fun unpair() {
        stopLink()
        store.clearPairing()
        LinkService.stop(context)
    }

    fun stopDemo() = stopLink()

    private fun stopLink() {
        closeDiff()
        usage = null
        recap = null
        services = emptyList()
        fallback?.stop()
        fallback = null
        relayConnector = null
        route = null
        relayIssue = com.coucou.android.link.RelayIssue.NONE
        finder.stop()
        netWatch.stop()
        screenWatch.stop()
        KeepAliveAlarm.cancel(context)
        health = health.recovered()
        currentPairing = null
        link?.stop()
        link = null
        mode = Mode.NONE
        linkState = LinkState.DISCONNECTED
        desktopName = null
        sessions = emptyList()
        dropApprovals()
        chatLinkLost()
        wantAllow = null
        lastState.clear()
        notifier.cancelAllStatus()
    }

    /** True if the decision was sent (or applied to the demo). Allow is gated by the biometric prompt in the UI. */
    fun decide(fingerprint: String, allow: Boolean): Boolean {
        val request = approvals.firstOrNull { it.fingerprint == fingerprint }
        if (allow && request != null && !com.coucou.android.core.ApprovalSheetPlan.canAllowHere(request)) {
            // Whatever asked (a stale notification, a test): a command that was cut is never allowed from here. It stays pending.
            message = context.getString(R.string.approval_on_computer)
            return false
        }
        val ok = link?.decide(fingerprint, allow) ?: false
        if (ok && request != null) {
            // The phone's own history never keeps the command: a label and at most the program's name.
            recordDecision(Decision(agentName(request.pillId), request.tool, com.coucou.android.core.SafeText.requestLabel(request.tool, request.command), allow, System.currentTimeMillis()))
        }
        if (!ok) {
            message = context.getString(R.string.msg_not_pending)
            removeApproval(fingerprint) // it cannot be answered any more: no card or pill that lingers
        }
        return ok
    }

    /** Every card goes: the desktop offers a request again if it is still pending once we reconnect. */
    private fun dropApprovals() {
        questions.forEach { expiry.remove(it.fingerprint)?.let { r -> main.removeCallbacks(r) } }
        questions = emptyList()
        overlay.hide()
        expiry.values.forEach { main.removeCallbacks(it) }
        expiry.clear()
        approvals.forEach { notifier.cancelApproval(it.fingerprint) }
        approvals = emptyList()
        refreshIsland()
    }

    private fun removeApproval(fingerprint: String) {
        expiry.remove(fingerprint)?.let { main.removeCallbacks(it) }
        approvals = approvals.filter { it.fingerprint != fingerprint }
        notifier.cancelApproval(fingerprint)
        refreshIsland()
    }

    // ── LinkListener (link thread) ───────────────────────────────────────────

    override fun onState(state: LinkState) {
        main.post {
            linkState = state
            relayIssue = relayConnector?.issue ?: com.coucou.android.link.RelayIssue.NONE
            if (state == LinkState.CONNECTED) {
                health = health.recovered()
                screenWasOff = power?.isInteractive == false // the screen is off right now: this link starts its life asleep
            }
            if (state == LinkState.CONNECTED) finder.connected() // found it (or never lost it): stop looking
            // A card for a request we can no longer answer would only produce "no longer pending".
            if (state != LinkState.CONNECTED && mode == Mode.PAIRED) dropApprovals()
            if (state != LinkState.CONNECTED) chatLinkLost()
            refreshIsland()
        }
    }

    override fun onWelcome(desktopName: String, os: String) {
        main.post { if (mode != Mode.DEMO && desktopName.isNotBlank()) this.desktopName = desktopName }
    }

    override fun onCaps(caps: Set<String>) {
        main.post {
            chatOffered = Protocol.CAP_CHAT in caps
            detailsOffered = Protocol.CAP_DETAILS in caps
            diffsOffered = Protocol.CAP_DIFFS in caps
            if (Protocol.CAP_USAGE !in caps) usage = null
            if (Protocol.CAP_RECAP !in caps) recap = null
            pushGlance() // the Usage Ring says to turn it on
            if (Protocol.CAP_SERVICES !in caps) services = emptyList()
        }
    }

    override fun onUsage(usage: com.coucou.android.link.UsageSnapshot) {
        main.post {
            this.usage = usage.takeIf { it.claude != null || it.codex != null }
            pushGlance() // the Usage Ring follows it
        }
    }

    override fun onRecap(recap: com.coucou.android.link.Recap?) {
        main.post { this.recap = recap }
    }

    override fun onServices(cards: List<com.coucou.android.link.ServiceCard>) {
        main.post { services = cards }
    }

    override fun onPrefs(outfit: String) {
        main.post { applyComputerOutfit(outfit) }
    }

    fun applyComputerOutfit(outfit: String) {
        val v = com.coucou.android.mochi.outfit.Wardrobe.parse(outfit)
        computerOutfit = v
        kv.put("computer_outfit", v)
    }

    override fun onChatModels(models: List<ChatModel>) {
        main.post {
            chatModels = models
            chatModel = ChatModels.pick(models, chatModel)
        }
    }

    override fun onChatDelta(id: String, text: String) {
        main.post { chatSession.onDelta(id, text); chatChanged(save = false) }
    }

    override fun onChatDone(id: String, text: String?) {
        main.post { chatSession.onDone(id, text); chatChanged(save = true) }
    }

    override fun onChatError(id: String, reason: String, message: String) {
        main.post { chatSession.onError(id, reason); chatChanged(save = true) }
    }

    override fun onSessions(sessions: List<SessionInfo>) {
        main.post {
            this.sessions = sessions
            val minute = java.time.LocalTime.now().let { it.hour * 60 + it.minute }
            for (s in sessions) {
                val prev = lastState.put(s.pillId, s.state)
                // A task just finished (not one already finished when the link came back), on a real computer: the demo loops and never counts.
                if (mode == Mode.PAIRED && prev != null && prev != BotState.FINISHED && s.state == BotState.FINISHED) todayCounter.increment()
                val name = agentName(s.pillId)
                val sound = com.coucou.android.mochi.MochiConst.STATE_SOUND[s.state]
                if (sound != null && StatusPolicy.stateSoundWanted(prev, s.state, settings)) sounds.play(sound)
                val a = StatusPolicy.announce(prev, s.state, settings, minute, inForeground, s.pillId)
                if (a.sound && sound != null) sounds.play(sound)
                if (a.notify) notifier.showStatus(s.pillId, name, s.state, s.statusText)
                IslandPlan.flash(prev, s, settings, minute, islandAllowed(), this::agentName)?.let { overlay.flash(it) }
                // The agent moved on: the notice about the last state is stale.
                if (prev != s.state && s.state !in NEWSWORTHY) notifier.cancelStatus(s.pillId)
            }
            lastState.keys.retainAll(sessions.map { it.pillId }.toSet())
            refreshIsland()
        }
    }

    override fun onApproval(request: ApprovalRequest) {
        main.post {
            approvals = approvals.filter { it.fingerprint != request.fingerprint } + request
            // One announcement only: the island if it can show, else the heads-up notification.
            refreshIsland()
            notifier.showApproval(request, agentName(request.pillId), OverlayPolicy.approvalAlert(overlay.isShowingRequest()))
            // Offered for 120 s from now, by this phone's clock (the notification times out then too).
            expiry.remove(request.fingerprint)?.let { main.removeCallbacks(it) }
            val gone = Runnable { removeApproval(request.fingerprint) }
            expiry[request.fingerprint] = gone
            main.postDelayed(gone, Protocol.APPROVAL_TTL_MS)
        }
    }

    override fun onQuestion(request: QuestionRequest) {
        main.post {
            questions = questions.filter { it.fingerprint != request.fingerprint } + request
            // Offered for 120 s from now, like an approval; the computer drops it at 115 s.
            expiry.remove(request.fingerprint)?.let { main.removeCallbacks(it) }
            val gone = Runnable { removeQuestion(request.fingerprint) }
            expiry[request.fingerprint] = gone
            main.postDelayed(gone, Protocol.APPROVAL_TTL_MS)
        }
    }

    private fun removeQuestion(fingerprint: String) {
        expiry.remove(fingerprint)?.let { main.removeCallbacks(it) }
        questions = questions.filter { it.fingerprint != fingerprint }
    }

    /** The question of this agent, if one waits for the phone's answer. */
    fun questionFor(pillId: String): QuestionRequest? = questions.firstOrNull { it.pillId == pillId }

    /**
     * Sends the picks; the lock check has already happened in the UI (BiometricGate). True if it was sent. What was
     * picked is not logged, not stored and not put in the history.
     */
    fun answerQuestion(fingerprint: String, picks: List<List<String>>): Boolean {
        val sent = link?.answer(fingerprint, picks) ?: false
        if (sent) removeQuestion(fingerprint)
        return sent
    }

    // ── A file's change (cap `diffs`) ──────────────────────────────────────────────────

    private val diffAssembler = com.coucou.android.core.DiffAssembler()
    private val diffTimeout = Runnable {
        (diffState as? com.coucou.android.core.DiffState.Loading)?.let { diffState = com.coucou.android.core.DiffState.Failed(it.name) }
        diffAssembler.cancel()
    }

    /** What the file-change sheet shows; Idle closes it. The lines are held only while it is open. */
    var diffState by mutableStateOf<com.coucou.android.core.DiffState>(com.coucou.android.core.DiffState.Idle); private set

    /** Opens the sheet for a file of a session's list and asks the computer for its lines. */
    fun openDiff(pillId: String, file: com.coucou.android.link.FileChange) {
        diffState = com.coucou.android.core.DiffState.Loading(pillId, file.id, file.name)
        diffAssembler.expect(pillId, file.id)
        main.removeCallbacks(diffTimeout)
        if (link?.getDiff(pillId, file.id) == true) main.postDelayed(diffTimeout, DIFF_WAIT_MS)
        else diffState = com.coucou.android.core.DiffState.Failed(file.name)
    }

    /** Closes the sheet and forgets the lines. */
    fun closeDiff() {
        main.removeCallbacks(diffTimeout)
        diffAssembler.cancel()
        diffState = com.coucou.android.core.DiffState.Idle
    }

    override fun onDiff(part: com.coucou.android.link.ServerMsg.Diff) {
        main.post {
            val done = diffAssembler.accept(part) ?: return@post
            main.removeCallbacks(diffTimeout)
            if (diffState is com.coucou.android.core.DiffState.Loading) diffState = com.coucou.android.core.DiffState.Ready(done)
        }
    }

    override fun onApprovalResolved(fingerprint: String) {
        main.post {
            removeQuestion(fingerprint)
            removeApproval(fingerprint)
            if (wantAllow == fingerprint) wantAllow = null
        }
    }

    /** The computer replaced the relay's access key: this phone follows it (kept encrypted) and reconnects with it. */
    override fun onRelayAccess(access: String) {
        main.post {
            val p = currentPairing ?: return@post
            val r = p.relay ?: return@post
            if (r.access == access) return@post
            val q = p.copy(relay = r.copy(access = access))
            store.savePairing(q)
            currentPairing = q
            restartLink(q)
        }
    }

    /** A link that had worked ended on its own: remembered with its reason, so Home can say what happened. */
    override fun onLinkLost(reason: LostReason) {
        main.post {
            health = health.lost(System.currentTimeMillis(), reason, screenWasOff)
            kv.put("link_drops_off", health.dropsWhileScreenOff)
        }
    }

    override fun onConnectFailed(consecutive: Int) {
        main.post { health = health.failedAttempt(consecutive) }
        // The saved address failed: now (and only now) look for the computer on the network.
        if (consecutive >= DiscoveryPolicy.FAILURES_BEFORE_DISCOVERY) main.post { if (mayDiscover()) finder.request() }
    }

    override fun onError(code: String, message: String) {
        main.post {
            this.message = if (code == "auth") context.getString(R.string.msg_rejected)
            else "${context.getString(R.string.msg_link_error)}: $message"
        }
    }

    private companion object {
        /** How long the sheet waits for the lines of a file before saying it could not load them. */
        const val DIFF_WAIT_MS = 10_000L
        val NEWSWORTHY = setOf(BotState.QUESTION, BotState.ERROR, BotState.FINISHED, BotState.RATELIMIT)
    }
}
