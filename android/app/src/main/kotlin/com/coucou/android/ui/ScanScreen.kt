package com.coucou.android.ui

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import com.coucou.android.core.IconKind
import com.coucou.android.core.IslandSurface
import com.coucou.android.core.Spacing
import com.coucou.android.core.Tokens
import com.coucou.android.core.TypeScale
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.coucou.android.R
import com.coucou.android.core.ScanPermission
import com.coucou.android.scan.QrDecoder
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.delay

private const val ASKED_KEY = "camera_asked"

private tailrec fun Context.activity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.activity()
    else -> null
}

/**
 * Reads the pairing QR code with the camera. The camera is asked for only here, used only while this screen is
 * showing (it is released when the screen is left, paused, or a code was accepted), and no picture is kept or
 * sent: each frame is looked at for a code and dropped. [onText] gets the text of a code and says whether it was
 * a Coucou pairing code; anything else is ignored with a short hint.
 */
@Composable
fun ScanScreen(onBack: () -> Unit, onText: (String) -> Boolean) {
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    val prefs = remember { context.getSharedPreferences("coucou_ui", Context.MODE_PRIVATE) }
    fun hasCamera() = context.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
    var granted by remember { mutableStateOf(hasCamera()) }
    var asked by remember { mutableStateOf(prefs.getBoolean(ASKED_KEY, false)) }
    var cameraFailed by remember { mutableStateOf(false) }
    var wrong by remember { mutableStateOf(false) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        asked = true
        prefs.edit().putBoolean(ASKED_KEY, true).apply()
        granted = ok
    }
    // Back from Android's settings: the user may have allowed it there.
    DisposableEffect(owner) {
        val obs = LifecycleEventObserver { _, e -> if (e == Lifecycle.Event.ON_RESUME) granted = hasCamera() }
        owner.lifecycle.addObserver(obs)
        onDispose { owner.lifecycle.removeObserver(obs) }
    }
    LaunchedEffect(wrong) { if (wrong) { delay(2_500); wrong = false } }

    val state = ScanPermission.state(
        granted, asked, canExplain = context.activity()?.shouldShowRequestPermissionRationale(Manifest.permission.CAMERA) == true,
    )

    val backLabel = stringResource(R.string.action_back)
    // A camera screen: black, edge to edge, with light text.
    Column(
        Modifier.fillMaxSize().background(Color(IslandSurface.BLACK)).windowInsetsPadding(WindowInsets.statusBars).padding(horizontal = Gutter),
        verticalArrangement = Arrangement.spacedBy(Gap),
    ) {
        Row(Modifier.padding(top = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier.size(Spacing.MIN_TOUCH.dp).clip(CircleShape).clickable(role = Role.Button, onClick = onBack).semantics { contentDescription = backLabel },
                contentAlignment = Alignment.Center,
            ) { CoucouIcon(IconKind.BACK, tint = Color(IslandSurface.TEXT), size = 24.dp) }
            Text(stringResource(R.string.scan_title), style = TypeScale.TITLE.style(Color(IslandSurface.TEXT)), maxLines = 1)
        }
        when {
            state == ScanPermission.State.GRANTED && !cameraFailed -> {
                Box(Modifier.weight(1f).fillMaxWidth().clip(RoundedCornerShape(14.dp))) {
                    val current by rememberUpdatedState(onText)
                    CameraView(
                        onFound = { text ->
                            val accepted = current(text)
                            if (!accepted) wrong = true
                            accepted
                        },
                        onFailed = { cameraFailed = true },
                    )
                    Viewfinder()
                }
                Text(
                    stringResource(if (wrong) R.string.scan_not_pairing else R.string.scan_hint), Modifier.fillMaxWidth().padding(bottom = Gap),
                    style = TypeScale.BODY.style(if (wrong) Color(Tokens.DARK.danger) else Color(IslandSurface.TEXT_DIM)).copy(textAlign = TextAlign.Center),
                )
            }
            state == ScanPermission.State.GRANTED -> Message(stringResource(R.string.scan_camera_error), onBack)
            state == ScanPermission.State.ASK -> {
                Text(stringResource(R.string.scan_why), Modifier.padding(top = Gap), style = TypeScale.BODY.style(Color(IslandSurface.TEXT)))
                PillButton(stringResource(R.string.scan_allow), { launcher.launch(Manifest.permission.CAMERA) }, Modifier.fillMaxWidth(), PillKind.PRIMARY, onDark = true)
                PillButton(stringResource(R.string.scan_paste_instead), onBack, Modifier.fillMaxWidth(), onDark = true)
            }
            else -> {
                Text(stringResource(R.string.scan_blocked), Modifier.padding(top = Gap), style = TypeScale.BODY.style(Color(IslandSurface.TEXT)))
                PillButton(
                    stringResource(R.string.scan_open_settings),
                    { context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}"))) },
                    Modifier.fillMaxWidth(), PillKind.PRIMARY, onDark = true,
                )
                PillButton(stringResource(R.string.scan_paste_instead), onBack, Modifier.fillMaxWidth(), onDark = true)
            }
        }
    }
}

@Composable
private fun Message(text: String, onBack: () -> Unit) {
    Text(text, Modifier.padding(top = Gap), style = TypeScale.BODY.style(Color(IslandSurface.TEXT)))
    PillButton(stringResource(R.string.scan_paste_instead), onBack, Modifier.fillMaxWidth(), onDark = true)
}

/** A dimmed frame with a clear square in the middle, where the code should be. */
@Composable
private fun Viewfinder() {
    val accent = Color.White
    Canvas(Modifier.fillMaxSize()) {
        val side = size.minDimension * 0.7f
        val left = (size.width - side) / 2f
        val top = (size.height - side) / 2f
        val dim = Color(0x99000000)
        drawRect(dim, Offset.Zero, Size(size.width, top))
        drawRect(dim, Offset(0f, top + side), Size(size.width, size.height - top - side))
        drawRect(dim, Offset(0f, top), Size(left, side))
        drawRect(dim, Offset(left + side, top), Size(size.width - left - side, side))
        drawRoundRect(accent, Offset(left, top), Size(side, side), CornerRadius(16.dp.toPx()), style = Stroke(3.dp.toPx()))
    }
}

/**
 * The camera preview and the code reader. Bound to this screen's lifecycle and unbound when it leaves the
 * composition, so the camera is released on leaving, on pausing and once a code was accepted. [onFound]
 * returns whether the code was accepted; after an accepted one no more frames are read.
 */
@Composable
private fun CameraView(onFound: (String) -> Boolean, onFailed: () -> Unit) {
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    // COMPATIBLE (a texture) so the rounded corners and the viewfinder above it draw properly.
    val previewView = remember {
        PreviewView(context).apply {
            implementationMode = PreviewView.ImplementationMode.COMPATIBLE
            scaleType = PreviewView.ScaleType.FILL_CENTER
        }
    }
    val executor = remember { Executors.newSingleThreadExecutor() }
    val done = remember { AtomicBoolean(false) }
    val found by rememberUpdatedState(onFound)
    val failed by rememberUpdatedState(onFailed)

    DisposableEffect(owner) {
        val decoder = QrDecoder()
        var provider: ProcessCameraProvider? = null
        var analysis: ImageAnalysis? = null
        var lastWrong = ""
        var lastWrongAt = 0L
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            try {
                val p = future.get()
                provider = p
                val preview = Preview.Builder().build().also { it.setSurfaceProvider(previewView.surfaceProvider) }
                val a = ImageAnalysis.Builder()
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .setResolutionSelector(
                        ResolutionSelector.Builder()
                            .setResolutionStrategy(ResolutionStrategy(android.util.Size(1280, 720), ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER))
                            .build(),
                    )
                    .build()
                a.setAnalyzer(executor) { image: ImageProxy ->
                    try {
                        if (!done.get()) {
                            val plane = image.planes[0] // brightness only
                            val buf = plane.buffer
                            val bytes = ByteArray(buf.remaining()).also { buf.get(it) }
                            val text = decoder.decode(bytes, plane.rowStride, image.width, image.height)
                            val now = System.currentTimeMillis()
                            // The same wrong code in view is not reported again for a moment.
                            if (text != null && (text != lastWrong || now - lastWrongAt > 2_500)) {
                                var accepted = false
                                val latch = java.util.concurrent.CountDownLatch(1)
                                previewView.post { accepted = found(text); latch.countDown() }
                                latch.await(2, java.util.concurrent.TimeUnit.SECONDS)
                                if (accepted) {
                                    done.set(true)
                                    previewView.post { provider?.unbindAll() } // released at once, before the screen even changes
                                } else {
                                    lastWrong = text; lastWrongAt = now
                                }
                            }
                        }
                    } finally {
                        image.close() // the frame is dropped; nothing is kept
                    }
                }
                analysis = a
                p.unbindAll()
                p.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, preview, a)
            } catch (e: Exception) {
                failed()
            }
        }, context.mainExecutor)
        onDispose {
            done.set(true)
            analysis?.clearAnalyzer()
            provider?.unbindAll()
            executor.shutdown()
        }
    }
    AndroidView({ previewView }, Modifier.fillMaxSize())
}
