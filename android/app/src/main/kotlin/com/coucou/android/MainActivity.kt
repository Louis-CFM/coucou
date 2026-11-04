package com.coucou.android

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.WindowManager
import android.os.SystemClock
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items as gridItems
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.foundation.lazy.rememberLazyListState
import kotlinx.coroutines.launch
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.runtime.SideEffect
import androidx.core.view.WindowCompat
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.coucou.android.app.AppModel
import com.coucou.android.app.BiometricGate
import com.coucou.android.app.CoucouApp
import com.coucou.android.app.Mode
import com.coucou.android.app.Notifications
import com.coucou.android.core.ApprovalSheetPlan
import com.coucou.android.core.HomeText
import com.coucou.android.core.Nav
import com.coucou.android.core.Pills
import com.coucou.android.core.Screen
import com.coucou.android.core.SecureScreens
import com.coucou.android.link.ApprovalRequest
import com.coucou.android.link.QuestionRequest
import com.coucou.android.link.LinkState
import com.coucou.android.link.PairingPayload
import com.coucou.android.mochi.BotEmote
import com.coucou.android.mochi.BotState
import com.coucou.android.mochi.MochiEngine
import com.coucou.android.mochi.MochiView
import com.coucou.android.ui.Panel
import com.coucou.android.ui.c
import com.coucou.android.ui.style
import com.coucou.android.ui.tokens
import com.coucou.android.core.TypeScale
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.heightIn
import androidx.compose.ui.semantics.Role
import com.coucou.android.ui.CoucouTheme
import com.coucou.android.core.HomePanel
import com.coucou.android.link.DiscoveryState
import com.coucou.android.ui.AddressSheet
import com.coucou.android.ui.BatteryCard
import com.coucou.android.ui.DiagnosticsScreen
import com.coucou.android.ui.LicencesScreen
import com.coucou.android.ui.LinkHealthPanel
import com.coucou.android.ui.AgentRows
import com.coucou.android.ui.DiscoveryHint
import com.coucou.android.ui.ApprovalSheet
import com.coucou.android.ui.MessagePanel
import com.coucou.android.ui.PairingScreen
import com.coucou.android.ui.DiffSheet
import com.coucou.android.ui.QuestionSheet
import com.coucou.android.ui.ServicesPanel
import com.coucou.android.ui.UsagePanel
import com.coucou.android.ui.RecapPanel
import com.coucou.android.ui.WardrobeScreen
import com.coucou.android.ui.HeroCard
import com.coucou.android.ui.RecentPanel
import com.coucou.android.ui.BarClearance
import com.coucou.android.ui.BottomBar
import com.coucou.android.ui.PairConfirm
import com.coucou.android.ui.ScanScreen
import com.coucou.android.ui.SessionScreen
import com.coucou.android.ui.ChatScreen
import com.coucou.android.ui.MochiTouch
import com.coucou.android.ui.HistoryScreen
import com.coucou.android.ui.SettingsScreen
import com.coucou.android.ui.StatusColors
import com.coucou.android.ui.Gap
import com.coucou.android.ui.Gutter
import com.coucou.android.ui.ScreenTitle
import com.coucou.android.ui.SectionTitle
import com.coucou.android.ui.linkDotColor
import com.coucou.android.ui.linkStatusText

class MainActivity : ComponentActivity() {
    private val model get() = (application as CoucouApp).model
    private var screen by mutableStateOf(Screen.HOME)
    /** The session whose details are open. */
    private var detailPill by mutableStateOf<String?>(null)
    /** The approval the user closed without deciding (the sheet stays down for it), and the session whose question is open. */
    private var closedApproval by mutableStateOf<String?>(null)
    private var questionPill by mutableStateOf<String?>(null)
    private var confirming = false
    override fun attachBaseContext(newBase: Context) {
        super.attachBaseContext(com.coucou.android.app.AppLanguage.wrap(newBase))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        model.languageChanged(com.coucou.android.app.AppLanguage.current(this))
        enableEdgeToEdge()
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
        model.resume()
        setContent {
            CoucouTheme(model.settings.theme, model.settings.dynamicColour) {
                // Dark icons on a light page; the camera screen is black in both themes, so its icons are light.
                val lightPage = !tokens().isDark && screen != Screen.SCAN
                SideEffect {
                    val bars = WindowCompat.getInsetsController(window, window.decorView)
                    bars.isAppearanceLightStatusBars = lightPage
                    bars.isAppearanceLightNavigationBars = lightPage
                }
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    Box(Modifier.fillMaxSize().windowInsetsPadding(if (screen == Screen.HOME || screen == Screen.SCAN) WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom) else WindowInsets.safeDrawing)) {
                        val tabs = Nav.tabs()
                        val keyboardOpen = WindowInsets.ime.getBottom(LocalDensity.current) > 0
                        val barVisible = Nav.barVisible(screen, keyboardOpen)
                        BackHandler(enabled = Nav.back(screen) != null) { Nav.back(screen)?.let { screen = it } }
                        // Chat keeps its message box above the bar; Home and Settings scroll under it (their own bottom padding).
                        Box(Modifier.fillMaxSize().padding(bottom = if (barVisible && screen == Screen.CHAT) BarClearance else 0.dp)) {
                        when (screen) {
                            Screen.SCAN -> ScanScreen(
                                onBack = { screen = Screen.HOME },
                                // True if it was a pairing code: the camera is released and the user is asked to confirm.
                                onText = { text -> model.requestPairing(text).also { if (it) screen = Screen.HOME } },
                            )
                            Screen.CHAT -> ChatScreen(model, onHome = { screen = Screen.HOME }, onSettings = { screen = Screen.SETTINGS })
                            Screen.SESSION -> SessionScreen(model, detailPill.orEmpty(), onBack = { screen = Screen.HOME })
                            Screen.GALLERY -> Gallery(onBack = { screen = Screen.SETTINGS })
                            Screen.SETTINGS -> SettingsScreen(
                                model, onHistory = { screen = Screen.HISTORY },
                                onGallery = { screen = Screen.GALLERY }, onWardrobe = { screen = Screen.WARDROBE }, onOverlay = ::setOverlay,
                                onDiagnostics = { screen = Screen.DIAGNOSTICS }, onLicences = { screen = Screen.LICENCES },
                            )
                            Screen.LICENCES -> LicencesScreen(onBack = { screen = Screen.SETTINGS })
                            Screen.WARDROBE -> WardrobeScreen(model, onBack = { screen = Screen.SETTINGS })
                            Screen.DIAGNOSTICS -> DiagnosticsScreen(model, onBack = { screen = Screen.SETTINGS })
                            Screen.HISTORY -> HistoryScreen(model, onBack = { screen = Screen.SETTINGS })
                            Screen.HOME -> if (model.mode == Mode.NONE) PairingScreen(model, onScan = { screen = Screen.SCAN }, onAbout = { screen = Screen.SETTINGS }) else Home(
                                model, onApprove = ::approve, onOverlay = ::setOverlay,
                                onSession = { detailPill = it; screen = Screen.SESSION },
                                onScan = { screen = Screen.SCAN }, onReview = { closedApproval = null }, onQuestion = { questionPill = it },
                                onHistory = { screen = Screen.HISTORY }, onDiagnostics = { screen = Screen.DIAGNOSTICS },
                            )
                        }
                        }
                        if (barVisible) {
                            BottomBar(
                                tabs, Nav.tabOf(screen), onSelect = { screen = Nav.screenOf(it) },
                                alert = model.approvals.isNotEmpty(), modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 16.dp),
                            )
                        }
                        // A request for permission rises over whatever is on screen until it is decided or closed.
                        val pending = ApprovalSheetPlan.next(model.approvals, closedApproval)
                        if (pending != null && screen != Screen.SCAN) ApprovalSheet(model, pending, onAllow = ::approve, onDismiss = { closedApproval = pending.fingerprint })
                        questionPill?.let { QuestionSheet(model, it, onDismiss = { questionPill = null }, onSend = ::sendAnswer) }
                        DiffSheet(model)
                        // Pairing, chat, an approval and a question never show in screenshots or in the recent-apps card.
                        val secure = SecureScreens.needed(
                            screen, pairing = model.mode == Mode.NONE, approvalSheetShown = pending != null && screen != Screen.SCAN,
                            questionSheetShown = questionPill != null, pairConfirmShown = model.pairRequest != null,
                        )
                        SideEffect {
                            if (secure) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE) else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                        // A scanned code or a link from the camera app: the user decides before anything is paired.
                        model.pairRequest?.let { PairConfirm(model, it) }
                    }
                }
            }
        }
        handle(intent)
    }

    override fun onStart() {
        super.onStart()
        model.inForeground = true
        model.refreshOverlayPermission() // maybe granted meanwhile, from this app's switch or Android's settings
        model.refreshBattery() // the battery setting may have been changed in Android's screen
    }

    override fun onStop() {
        model.inForeground = false
        super.onStop()
    }

    /**
     * The pill over other apps needs a one-time system permission. The choice is saved first: even if
     * Android recreates the app while the user is in Settings, it is remembered, and the pill works as
     * soon as the permission is there.
     */
    private fun setOverlay(on: Boolean) {
        model.useOverlay(on)
        if (on && !model.overlayPermitted()) {
            model.message = getString(R.string.msg_overlay_permission)
            startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName")))
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handle(intent)
    }

    /** A coucou://pair link (from the camera app or a browser) or a tap on an approval notification. */
    private fun handle(i: Intent?) {
        i ?: return
        Log.d("CoucouLaunch", "MainActivity intent: action=${i.action} data=${i.data != null}")
        i.data?.let { uri ->
            if (uri.scheme == "coucou") {
                // Opened from the camera app or a browser: never paired without the user's OK.
                if (!model.requestPairing(uri.toString())) model.message = getString(R.string.msg_bad_link)
                i.data = null // handled once: a rotation must not ask again
            }
        }
        // Never read from the intent: this activity is exported, any app could send these extras. The requests come
        // from LaunchActivity (ours, not exported) through the model, once.
        model.launch.takeSession()?.let { pill ->
            // A tap on a widget row. The session screen says so itself if it has ended, and fills in when the link is back.
            if (model.isPaired || model.mode != Mode.NONE) { detailPill = pill; screen = Screen.SESSION }
        }
        // A tap on a widget button: a screen of the closed list ([LaunchScreen]), even when the app is locked, not connected or not paired.
        model.launch.takeScreen()?.let { screen = it.screen }
        // Text shared to Coucou from another app (ShareActivity, which only keeps cleaned text): it waits in the model for the chat box.
        if (model.shareDraft.pending()) screen = Screen.CHAT
        val launch = model.launch.take() ?: return
        val fp = launch.fingerprint
        if (launch.allow) {
            val request = model.approvals.firstOrNull { it.fingerprint == fp }
            when {
                request != null -> approve(request)
                // The app was closed: the desktop offers the request again once the link is back.
                model.linkState != LinkState.CONNECTED -> model.wantAllow = fp
                else -> model.message = getString(R.string.msg_not_pending)
            }
        }
    }

    /**
     * An answer to a question: only after the same screen-lock check as Allow. The lock prompt shows what is about to be
     * sent (the labels picked); nothing about it is logged or stored.
     */
    private fun sendAnswer(request: QuestionRequest, picks: List<List<String>>) {
        if (confirming) return
        confirming = true
        BiometricGate.confirm(
            this, getString(R.string.question_confirm_title), picks.joinToString("; ") { it.joinToString(", ") }, getString(R.string.msg_need_lock),
            onSuccess = {
                confirming = false
                questionPill = null
                model.message = getString(if (model.answerQuestion(request.fingerprint, picks)) R.string.question_sent else R.string.question_not_sent)
            },
            onFail = { confirming = false; if (it.isNotBlank()) model.message = it },
        )
    }

    /** Allow: only after the biometric / screen-lock check. */
    private fun approve(r: ApprovalRequest) {
        if (confirming) return // a second tap must not open a second prompt
        if (!ApprovalSheetPlan.canAllowHere(r)) { model.message = getString(R.string.approval_on_computer); return }
        confirming = true
        BiometricGate.confirm(
            this, getString(R.string.action_allow), "${r.tool}: ${r.command}", getString(R.string.msg_need_lock),
            onSuccess = { confirming = false; model.decide(r.fingerprint, allow = true) },
            onFail = { confirming = false; if (it.isNotBlank()) model.message = it },
        )
    }
}

@Composable
private fun Home(
    model: AppModel, onApprove: (ApprovalRequest) -> Unit, onOverlay: (Boolean) -> Unit, onSession: (String) -> Unit,
    onScan: () -> Unit, onHistory: () -> Unit, onReview: () -> Unit, onQuestion: (String) -> Unit, onDiagnostics: () -> Unit,
) {
    val engines = remember { HashMap<String, MochiEngine>() }
    val miniEngines = remember { HashMap<String, MochiEngine>() }
    val touches = remember { HashMap<String, MochiTouch>() }
    val clock = remember { { SystemClock.elapsedRealtimeNanos() / 1e6 } }
    var selected by rememberSaveable { mutableStateOf<String?>(null) }
    val listState = rememberLazyListState()
    var addressOpen by rememberSaveable { mutableStateOf(false) }

    // Allow tapped on a notification before the link was back: open the prompt once the request is here.
    LaunchedEffect(model.approvals, model.wantAllow) {
        val fp = model.wantAllow ?: return@LaunchedEffect
        model.approvals.firstOrNull { it.fingerprint == fp }?.let {
            model.wantAllow = null
            onApprove(it)
        }
    }

    // The PC's Home panel: the agent that matters in a big card, the others as pills.
    val focus = HomePanel.focus(model.sessions, selected)
    val key = focus?.pillId ?: HOME_KEY
    val engine = engines.getOrPut(key) { MochiEngine(clock, sound = model.sounds) }
    val touch = touches.getOrPut(key) { MochiTouch(engine, model.sounds) { model.sessions.firstOrNull { it.pillId == key }?.state ?: BotState.IDLE } }
    val state = focus?.state ?: BotState.SLEEPING // no agent: a sleeping Mochi
    if (engine.state != state && !touch.dizzy) engine.setState(state)

    // The hero wears what the computer says, or what the user picked here (a new engine starts dressed, a change animates).
    val dressed = remember { HashSet<MochiEngine>() }
    model.dress().let { outfit -> if (dressed.add(engine)) engine.setOutfit(outfit, animated = false) else engine.setOutfit(outfit) }

    // The hero's Mochi wears its agent's colour, like the small ones (never white by default).
    engine.bodyColor = focus?.let { HomePanel.colorHex(it) }?.let { HomePanel.rgb(it) }

    val pair = HomePanel.link(model.isPaired, model.mode == Mode.DEMO, hasApproval = model.approvals.isNotEmpty())
    // Items, in order: the hero, [message], then the other agents, ask, recent.
    val others = HomePanel.others(model.sessions, focus)
    LazyColumn(
        state = listState,
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(bottom = BarClearance),
        verticalArrangement = Arrangement.spacedBy(Gap),
    ) {
        item {
            HeroCard(
                focus, engine, touch.modifier, pair, HomeText.running(model.sessions),
                linkDot = linkDotColor(model), linkText = linkStatusText(model),
                onDetails = if (focus != null && HomePanel.hasDetails(focus)) ({ onSession(focus.pillId) }) else null,
                onQuestion = if (focus != null && focus.state == BotState.QUESTION) ({ onQuestion(focus.pillId) }) else null,
                canAnswer = focus != null && model.questionFor(focus.pillId) != null,
                onLink = {
                    when (pair) {
                        HomePanel.Link.PAIR -> onScan() // not reachable on Home (no computer shows the pairing screen), harmless
                        HomePanel.Link.APPROVAL -> onReview()
                        HomePanel.Link.NONE -> {}
                    }
                },
            )
        }
        // The link had worked and ended: what happened and how long ago, instead of a silent state. And, only if it would help, the battery setting.
        if (model.mode == Mode.PAIRED && model.linkState != LinkState.CONNECTED) {
            item { Box(Modifier.padding(horizontal = Gutter)) { LinkHealthPanel(model, onDiagnostics) } }
        }
        if (model.batteryHintVisible) item { Box(Modifier.padding(horizontal = Gutter)) { BatteryCard(model) } }
        // The saved address failed and a search found nothing: a calm hint with two ways out.
        if (model.mode == Mode.PAIRED && model.linkState != LinkState.CONNECTED && model.discovery == DiscoveryState.NOT_FOUND) {
            item { Box(Modifier.padding(horizontal = Gutter)) { DiscoveryHint(onPairAgain = onScan, onEnterAddress = { addressOpen = true }) } }
        }
        model.message?.let { msg ->
            item { Box(Modifier.padding(horizontal = Gutter)) { MessagePanel(msg) { model.message = null } } }
        }


        if (others.isNotEmpty()) {
            item {
                Box(Modifier.padding(horizontal = Gutter)) {
                    AgentRows(
                        others,
                        engineFor = { s ->
                            miniEngines.getOrPut(s.pillId) {
                                MochiEngine(clock).apply {
                                    isMini = true
                                    bodyColor = HomePanel.colorHex(s)?.let { HomePanel.rgb(it) }
                                }
                            }.also {
                                it.bodyColor = HomePanel.colorHex(s)?.let { hex -> HomePanel.rgb(hex) }
                                if (it.state != s.state) it.setState(s.state)
                            }
                        },
                        onPick = { selected = it.pillId },
                    )
                }
            }
        }

        if (model.recap != null) item { Box(Modifier.padding(horizontal = Gutter)) { RecapPanel(model.recap) } }
        if (model.usage != null) item { Box(Modifier.padding(horizontal = Gutter)) { UsagePanel(model.usage) } }
        if (model.services.isNotEmpty()) item { Box(Modifier.padding(horizontal = Gutter)) { ServicesPanel(model.services) } }
        item { Box(Modifier.padding(horizontal = Gutter)) { RecentPanel(model.decisions, onHistory) } }

        // Only when the switch is on but Android still refuses: the one thing Home must say about it.
        if (model.overlayWished && !model.overlayPermission) item { Box(Modifier.padding(horizontal = Gutter)) { OverlayHint(onOverlay) } }
        item { Spacer(Modifier.height(Gutter)) }
    }
    // After the list, so it draws over it.
    if (addressOpen) AddressSheet(model) { addressOpen = false }
}

private const val HOME_KEY = "home"

@Composable
private fun OverlayHint(onOverlay: (Boolean) -> Unit) {
    Panel {
        Row(Modifier.padding(start = Gutter), verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.overlay_missing), Modifier.weight(1f).padding(vertical = 12.dp), style = TypeScale.SECONDARY.style(tokens().textDim.c()))
            Text(
                stringResource(R.string.overlay_allow),
                Modifier.heightIn(min = 48.dp).clickable(role = Role.Button) { onOverlay(true) }.padding(horizontal = 16.dp, vertical = 14.dp),
                style = TypeScale.LABEL.style(tokens().text.c()), maxLines = 1,
            )
        }
    }
}

/** Every state and emote, drawn live. Handy to check the port by eye. */
@Composable
private fun Gallery(onBack: () -> Unit) {
    val clock = remember { { SystemClock.elapsedRealtimeNanos() / 1e6 } }
    val states = remember { BotState.entries.map { s -> s to MochiEngine(clock).apply { setState(s, force = true) } } }
    val emotes = remember { BotEmote.entries.map { e -> e to MochiEngine(clock).apply { setPermanentEmote(e) } } }
    Column(Modifier.padding(horizontal = Gutter)) {
        ScreenTitle(stringResource(R.string.gallery), onBack)
        Spacer(Modifier.height(Gap))
        LazyVerticalGrid(GridCells.Fixed(3), horizontalArrangement = Arrangement.spacedBy(Gap), verticalArrangement = Arrangement.spacedBy(Gap)) {
            gridItems(states) { (s, e) -> GalleryCell(s.key, e) }
            gridItems(emotes) { (m, e) -> GalleryCell(m.key, e) }
        }
    }
}

@Composable
private fun GalleryCell(label: String, engine: MochiEngine) {
    Box(Modifier.fillMaxWidth()) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            MochiView(engine, Modifier.fillMaxWidth().aspectRatio(1f))
            Text(label, style = MaterialTheme.typography.labelSmall)
        }
    }
}
