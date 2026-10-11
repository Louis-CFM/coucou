package com.coucou.android.ui

import android.content.Context
import android.graphics.PixelFormat
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.WindowInsets
import android.view.WindowManager
import androidx.compose.foundation.background
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import com.coucou.android.core.IconKind
import com.coucou.android.core.MotionSpec
import com.coucou.android.core.IslandSurface
import com.coucou.android.core.Tokens
import com.coucou.android.core.TypeScale
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.ViewModelStoreOwner
import androidx.lifecycle.setViewTreeLifecycleOwner
import androidx.lifecycle.setViewTreeViewModelStoreOwner
import androidx.savedstate.SavedStateRegistry
import androidx.savedstate.SavedStateRegistryController
import androidx.savedstate.SavedStateRegistryOwner
import androidx.savedstate.setViewTreeSavedStateRegistryOwner
import com.coucou.android.R
import com.coucou.android.core.IslandBox
import com.coucou.android.core.IslandGeometry
import com.coucou.android.core.IslandSpec
import com.coucou.android.core.IslandTimeline
import com.coucou.android.core.OverlayPolicy
import com.coucou.android.core.PxRect
import com.coucou.android.core.Tracked
import com.coucou.android.mochi.BotState
import com.coucou.android.mochi.MochiEngine
import com.coucou.android.mochi.MochiView

/**
 * The notch of the desktop, for the phone: a black island hanging from the top of the screen,
 * centred on the camera cut-out, over whatever app is open. It drops while an agent works, shows
 * how it ended for 10 s, then goes back up with the PC's motion (spring when it grows, a 340 ms
 * curve when it shrinks). A permission request or a question keeps it open.
 *
 * When it opens and closes is decided by [IslandTimeline] (pure, tested); this class only draws it
 * and keeps one timer, for the next deadline. Nothing exists while it is hidden: the window is added
 * when it opens and removed when it has gone up, so there is no timer and no frame loop.
 * Needs the user's one-time "display over other apps" permission.
 */
class IslandOverlay(
    private val context: Context,
    private val clock: () -> Double,
    private val onAllow: (fingerprint: String) -> Unit,
    private val onDeny: (fingerprint: String) -> Unit,
    private val onOpen: () -> Unit,
) {
    private val wm = context.getSystemService(WindowManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private val timeline = IslandTimeline(clock)

    private var view: ComposeView? = null
    private var owner: Owner? = null
    private var box: IslandBox? = null
    private var shownAt = 0.0

    private var spec by mutableStateOf<IslandSpec?>(null)
    private val width = Tracked(0.0)
    private val height = Tracked(0.0)
    private val radius = Tracked(0.0)
    /** Bumped whenever a new target is set, to (re)start the frame loop that only runs while moving. */
    private var motionKey by mutableIntStateOf(0)

    private val deadline = Runnable { safely { timeline.tick(); sync() } }

    fun permitted(): Boolean = Settings.canDrawOverlays(context)

    /** Something is going on right now: an agent works, a question waits, a request waits. Null: nothing. */
    fun setActive(next: IslandSpec?) = safely {
        timeline.setActive(next)
        sync()
    }

    /** An agent finished, failed or hit a limit: shown for 10 s, then the island goes up. */
    fun flash(next: IslandSpec) = safely {
        timeline.flash(next)
        sync()
    }

    /** Close at once, without animation (Coucou came to the front, the switch went off, the link dropped). */
    fun hide() = safely {
        timeline.dismiss()
        removeView()
    }

    /** True when the island is on screen showing a request: the notification can then stay quiet. */
    fun isShowingRequest(): Boolean =
        view != null && timeline.phase == IslandTimeline.Phase.OPEN && timeline.current?.kind == IslandSpec.Kind.APPROVAL &&
            seenByUser()

    /** The island is a window of its own: nobody sees it with the screen off, in a screen saver or behind the lock screen. */
    private fun seenByUser(): Boolean = runCatching {
        context.getSystemService(android.os.PowerManager::class.java).isInteractive &&
            !context.getSystemService(android.app.KeyguardManager::class.java).isKeyguardLocked
    }.getOrDefault(false)

    /** The island is a nicety on top of the app: nothing that goes wrong with the window may reach the caller. */
    private inline fun safely(block: () -> Unit) {
        try {
            block()
        } catch (e: Exception) {
            Log.w(TAG, "island failed: ${e.javaClass.simpleName}")
            runCatching { timeline.dismiss(); removeView() }
        }
    }

    // ── From the timeline to the window ──────────────────────────────────────

    private fun sync() {
        main.removeCallbacks(deadline)
        val phase = timeline.phase
        val current = timeline.current
        Log.d(TAG, "phase=$phase content=${current?.kind}")
        if (phase == IslandTimeline.Phase.HIDDEN || current == null) {
            removeView()
            return
        }
        val opening = view == null
        if (!ensureView()) return
        val b = box ?: return
        if (spec?.kind != current.kind || spec?.fingerprint != current.fingerprint) shownAt = clock()
        spec = current
        val now = clock()
        if (opening) {
            width.jump(b.notchWidth.toDouble()); height.jump(0.0); radius.jump(b.cornerSmall.toDouble())
        }
        val reduced = MotionSpec.isReduced(Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f))
        if (phase == IslandTimeline.Phase.OPEN) {
            val (w, h) = IslandGeometry.sizeFor(b, current.kind)
            val corner = (if (current.kind == IslandSpec.Kind.WORKING) b.cornerSmall else b.cornerLarge).toDouble()
            // "Remove animations": no spring, the island simply appears at its size.
            if (reduced) { width.jump(w.toDouble()); height.jump(h.toDouble()); radius.jump(corner) }
            else { width.goTo(w.toDouble(), now); height.goTo(h.toDouble(), now); radius.goTo(corner, now) }
        } else if (reduced) {
            width.jump(b.notchWidth.toDouble()); height.jump(0.0); radius.jump(b.cornerSmall.toDouble())
        } else {
            // Back up into the notch: same curve as the PC.
            width.curveTowards(b.notchWidth.toDouble(), now); height.curveTowards(0.0, now); radius.curveTowards(b.cornerSmall.toDouble(), now)
        }
        motionKey++
        timeline.nextDeadline()?.let { main.postDelayed(deadline, (it - clock()).toLong().coerceAtLeast(0)) }
    }

    private fun removeView() {
        main.removeCallbacks(deadline)
        view?.let { runCatching { wm.removeView(it) } }
        view = null
        owner?.destroy()
        owner = null
        spec = null
    }

    private fun measure(): IslandBox {
        val density = context.resources.displayMetrics.density
        val metrics = wm.currentWindowMetrics
        val insets = metrics.windowInsets
        val cutout = insets.displayCutout?.boundingRectTop?.let { PxRect(it.left, it.top, it.right, it.bottom) }
        val statusBar = insets.getInsetsIgnoringVisibility(WindowInsets.Type.statusBars()).top
            .takeIf { it > 0 } ?: (24 * density).toInt()
        return IslandGeometry.place(metrics.bounds.width(), density, cutout, statusBar)
    }

    private fun ensureView(): Boolean {
        if (view != null) return true
        val b = measure()
        box = b
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            // Not focusable and not modal: touches outside the island go to the app underneath. It may
            // extend into the display cut-out so its black merges with the camera hole.
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            x = b.centerOffsetX
            y = 0
            layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
        }
        val lifecycleOwner = Owner()
        val v = ComposeView(context).apply {
            setViewTreeLifecycleOwner(lifecycleOwner)
            setViewTreeSavedStateRegistryOwner(lifecycleOwner)
            setViewTreeViewModelStoreOwner(lifecycleOwner)
            setContent { Island() }
        }
        return try {
            wm.addView(v, params)
            owner = lifecycleOwner
            view = v
            true
        } catch (e: Exception) {
            Log.w(TAG, "cannot add the window: ${e.javaClass.simpleName}") // permission taken away meanwhile
            lifecycleOwner.destroy()
            false
        }
    }

    /** Every tap goes through here: one made in the first moments is ignored (see OverlayPolicy). */
    private fun tap(what: String, action: () -> Unit) {
        if (!OverlayPolicy.tapAccepted(shownAt, clock())) {
            Log.d(TAG, "ignored an early tap on $what")
            return
        }
        action()
    }

    // ── What is drawn ────────────────────────────────────────────────────────

    // The island is black: it is the camera hole grown. Colours are the shared always-dark ones.
    private val ink = Color(IslandSurface.BLACK)
    private val dim = Color(IslandSurface.TEXT_DIM)

    @Composable
    private fun Island() {
        var frame by remember { mutableLongStateOf(0L) }
        // Runs only while something is moving; when it stops, nothing redraws and nothing is scheduled.
        LaunchedEffect(motionKey) {
            var last = 0L
            while (width.animating || height.animating || radius.animating) {
                androidx.compose.runtime.withFrameNanos { ns ->
                    val dt = if (last == 0L) 1.0 / 60 else ((ns - last) / 1e9).coerceIn(0.0, 0.1)
                    last = ns
                    val now = clock()
                    width.step(dt, now); height.step(dt, now); radius.step(dt, now)
                    frame = ns
                }
            }
            if (timeline.phase == IslandTimeline.Phase.RETRACTING) {
                timeline.retractFinished()
                removeView()
            }
        }
        frame // read, so the island redraws as it moves
        val b = box ?: return
        val s = spec ?: return
        val density = LocalDensity.current
        fun px(v: Double): Dp = with(density) { v.toFloat().toDp() }
        val topInset = px(b.topInset.toDouble())
        val (targetW, targetH) = IslandGeometry.sizeFor(b, s.kind)
        // The content fades in as the island opens and out as it goes up.
        val open = ((height.value / targetH.toDouble()) - 0.35) / 0.55
        val corner = px(radius.value)
        val ear = IslandGeometry.EAR_DP.dp
        CompositionLocalProvider(LocalTokens provides Tokens.DARK) {
            // The island plus a concave flare on each side: its top is flush with the screen's edge and
            // merges with the camera hole, instead of hanging as a bar below it.
            Box(Modifier.width(px(width.value) + ear * 2).height(px(height.value))) {
                Canvas(Modifier.matchParentSize()) { drawFlares(ear.toPx().coerceAtMost(size.height), ink) }
                Box(
                    Modifier.align(Alignment.TopCenter).width(px(width.value)).fillMaxHeight()
                        .clip(RoundedCornerShape(bottomStart = corner, bottomEnd = corner)).background(ink),
                ) {
                    Box(
                        Modifier.fillMaxWidth().padding(top = topInset).alpha(open.coerceIn(0.0, 1.0).toFloat()),
                        contentAlignment = Alignment.TopCenter,
                    ) {
                        Box(Modifier.requiredWidth(px(targetW.toDouble())).wrapContentHeight(Alignment.Top, unbounded = true)) {
                            when (s.kind) {
                                IslandSpec.Kind.WORKING -> WorkingStrip(s)
                                IslandSpec.Kind.APPROVAL -> RequestCard(s)
                                else -> ResultCard(s)
                            }
                        }
                    }
                }
            }
        }
    }

    /** The two flares: each is the square beside the island minus a quarter circle, so the black curves out to the screen's top edge. */
    private fun DrawScope.drawFlares(e: Float, color: Color) {
        if (e <= 0f) return
        val w = size.width
        val left = Path().apply {
            moveTo(0f, 0f); lineTo(e, 0f); lineTo(e, e)
            arcTo(Rect(Offset(0f, e), e), 0f, -90f, false)
            close()
        }
        val right = Path().apply {
            moveTo(w, 0f); lineTo(w - e, 0f); lineTo(w - e, e)
            arcTo(Rect(Offset(w, e), e), 180f, 90f, false)
            close()
        }
        drawPath(left, color)
        drawPath(right, color)
    }

    @Composable
    private fun WorkingStrip(s: IslandSpec) {
        val engine = remember(s.state) { MochiEngine(clock).apply { setState(s.state, force = true) } }
        Row(
            Modifier.fillMaxWidth().clickable { tap("the working strip") { onOpen() } }.padding(horizontal = 18.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            MochiView(engine, Modifier.size(34.dp))
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                Text(s.agent, color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (s.text.isNotBlank()) Text(s.text, color = dim, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }

    @Composable
    private fun ResultCard(s: IslandSpec) {
        val engine = remember(s.state) { MochiEngine(clock).apply { setState(s.state, force = true) } }
        val label = when (s.kind) {
            IslandSpec.Kind.ERROR -> R.string.notif_error
            IslandSpec.Kind.RATELIMIT -> R.string.notif_ratelimit
            IslandSpec.Kind.QUESTION -> R.string.notif_question
            else -> R.string.notif_finished
        }
        Row(
            Modifier.fillMaxWidth().clickable { tap("the result card") { onOpen() } }.padding(horizontal = 18.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            MochiView(engine, Modifier.size(52.dp))
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(s.agent, color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(label), color = dim, fontSize = 12.sp, maxLines = 1)
                }
                val text = if (s.kind == IslandSpec.Kind.QUESTION) stringResource(R.string.island_answer_on_pc) else s.text
                if (text.isNotBlank()) Text(text, color = Color.White, fontSize = 13.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
        }
    }

    @Composable
    private fun RequestCard(s: IslandSpec) {
        val engine = remember { MochiEngine(clock).apply { setState(BotState.APPROVAL, force = true) } }
        val fingerprint = s.fingerprint ?: return
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(Modifier.clickable { tap("the request header") { onOpen() } }, verticalAlignment = Alignment.CenterVertically) {
                MochiView(engine, Modifier.size(40.dp))
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Text(s.agent, style = TypeScale.SECONDARY.style(dim), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    // What kind of action, never the command: the exact text is in the app and in the lock prompt.
                    Text(stringResource(R.string.approval_wants, s.text), style = TypeScale.HEADLINE.style(Color.White), maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                PillButton(stringResource(R.string.action_deny), { tap("Deny") { onDeny(fingerprint) } }, Modifier.weight(1f), onDark = true)
                if (s.canAllow) {
                    PillButton(
                        stringResource(R.string.action_allow), { tap("Allow") { onAllow(fingerprint) } }, Modifier.weight(1f), PillKind.PRIMARY, onDark = true,
                        icon = { CoucouIcon(IconKind.LOCK, tint = Color(IslandSurface.ON_PRIMARY), size = 18.dp) },
                    )
                }
            }
            Text(stringResource(if (s.canAllow) R.string.approval_hint else R.string.approval_on_computer), style = TypeScale.LABEL.style(dim), maxLines = 2)
        }
    }

    /** A window outside any activity has no lifecycle of its own: Compose needs one to run. */
    private class Owner : LifecycleOwner, SavedStateRegistryOwner, ViewModelStoreOwner {
        override val viewModelStore = ViewModelStore()
        private val registry = LifecycleRegistry(this)
        private val controller = SavedStateRegistryController.create(this)
        override val lifecycle: Lifecycle get() = registry
        override val savedStateRegistry: SavedStateRegistry get() = controller.savedStateRegistry

        init {
            controller.performAttach()
            controller.performRestore(null)
            registry.currentState = Lifecycle.State.RESUMED
        }

        fun destroy() {
            registry.currentState = Lifecycle.State.DESTROYED
            viewModelStore.clear()
        }
    }

    private companion object { const val TAG = "CoucouIsland" }
}
