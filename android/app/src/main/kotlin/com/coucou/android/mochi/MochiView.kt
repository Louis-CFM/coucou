package com.coucou.android.mochi

import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.repeatOnLifecycle
import com.coucou.android.mochi.MochiPainter.drawMochi

/**
 * Hosts a [MochiEngine] and redraws it every frame while the screen is visible.
 * The frame loop only runs while the lifecycle is STARTED, so a backgrounded app costs no CPU.
 */
@Composable
fun MochiView(engine: MochiEngine, modifier: Modifier = Modifier) {
    val frame = remember { mutableLongStateOf(0L) }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(engine, lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            var last = 0L
            while (true) {
                androidx.compose.runtime.withFrameNanos { ns ->
                    val dt = if (last == 0L) 1.0 / 60 else ((ns - last) / 1e9).coerceIn(0.0, 0.1)
                    last = ns
                    engine.update(dt)
                    frame.longValue = ns
                }
            }
        }
    }
    Canvas(modifier) {
        frame.longValue // read so the canvas redraws every frame
        drawMochi(engine, System.nanoTime() / 1e9)
    }
}
