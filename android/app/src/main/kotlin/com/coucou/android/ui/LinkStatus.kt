package com.coucou.android.ui

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import com.coucou.android.R
import com.coucou.android.app.AppModel
import com.coucou.android.app.Mode
import com.coucou.android.link.DiscoveryState
import com.coucou.android.link.LinkState

/** The line under the title ("Connected · My PC") and the colour of its dot, shared by Home and Settings. */
@Composable
fun linkStatusText(model: AppModel): String = when (model.mode) {
    Mode.NONE -> stringResource(R.string.status_not_connected)
    Mode.DEMO -> stringResource(R.string.demo_mode)
    Mode.PAIRED -> when (model.linkState) {
        LinkState.CONNECTED -> "${stringResource(R.string.status_connected)} · ${model.desktopName.orEmpty()}"
        LinkState.CONNECTING, LinkState.DISCONNECTED ->
            // The saved address failed and the network is being searched: say so, calmly.
            if (model.discovery == DiscoveryState.LOOKING) stringResource(R.string.status_looking)
            else stringResource(if (model.linkState == LinkState.CONNECTING) R.string.status_connecting else R.string.status_not_connected)
    }
}

fun linkDotColor(model: AppModel): Color = when {
    model.mode == Mode.DEMO -> StatusColors.busy
    model.mode == Mode.PAIRED && model.linkState == LinkState.CONNECTED -> StatusColors.online
    model.mode == Mode.PAIRED && (model.linkState == LinkState.CONNECTING || model.discovery == DiscoveryState.LOOKING) -> StatusColors.busy
    else -> StatusColors.offline
}
