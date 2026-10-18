package fr.louisraille.coucou.phone

import android.content.Context
import android.media.MediaPlayer

/**
 * Mochi's own sounds (upstream res/raw). Played in-app on a new waiting card —
 * the notification channel carries the same sound when the app is away.
 * Fire and forget: a failed play is silent.
 */
object Sounds {
    fun play(ctx: Context, res: Int) {
        runCatching {
            val p = MediaPlayer.create(ctx, res) ?: return
            p.setOnCompletionListener { it.release() }
            p.start()
        }
    }
}
