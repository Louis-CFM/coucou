package com.coucou.android.app

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import com.coucou.android.MainActivity
import com.coucou.android.core.Glance

/**
 * The quick-settings tile: on while the computer is connected, its second line is the headline of [Glance]. A tap
 * opens Coucou (it never approves or changes anything). The system calls [onStartListening] when the shade opens, so
 * it needs no timer; [requestUpdate] asks it to refresh when the picture changes while the shade is open.
 */
class GlanceTile : TileService() {
    override fun onStartListening() = paint(this)

    // Below Android 14 only the Intent form exists; lint flags the call although it is behind the version check.
    @SuppressLint("StartActivityAndCollapseDeprecated")
    override fun onClick() {
        val open = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(PendingIntent.getActivity(this, 0, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(open)
        }
    }

    companion object {
        /** Asks the system to refresh the tile if it is on screen (it ignores this when the tile is not added). */
        fun requestUpdate(context: android.content.Context) {
            runCatching { requestListeningState(context, ComponentName(context, GlanceTile::class.java)) }
        }

        private fun paint(tile: TileService) {
            val t = tile.qsTile ?: return
            val g: Glance = (tile.applicationContext as CoucouApp).model.glance()
            t.label = "Coucou"
            t.subtitle = g.headline
            t.state = if (g.connected) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
            t.updateTile()
        }
    }
}
