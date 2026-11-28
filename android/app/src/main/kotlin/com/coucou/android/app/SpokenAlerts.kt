package com.coucou.android.app

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.speech.tts.TextToSpeech
import com.coucou.android.core.SpokenAlertPolicy

/**
 * Says the one line of a spoken alert with Android's own TextToSpeech. What is said and when is decided by [SpokenAlertPolicy]; this
 * class only asks the phone (ringer, call, voices) and speaks. No network: only a voice that is installed and needs no connection is
 * used, and no library is involved. The engine exists only while the switch is on: off, it is shut down and nothing is held.
 * [onVoice] is told whether a voice is missing, so Settings can say why nothing is heard.
 */
class SpokenAlerts(context: Context, private val onVoice: (missing: Boolean) -> Unit) {
    private val app = context.applicationContext
    private val audio = app.getSystemService(AudioManager::class.java)
    private var tts: TextToSpeech? = null
    private var ready = false

    /** On: the engine is started (once). Off: it is stopped and released. */
    fun setEnabled(on: Boolean) {
        if (!on) {
            release()
            return
        }
        if (tts != null) return
        ready = false
        tts = runCatching {
            TextToSpeech(app) { status ->
                ready = status == TextToSpeech.SUCCESS
                if (ready) runCatching {
                    // The notification stream: its volume, and silent with the ringer.
                    tts?.setAudioAttributes(
                        AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build(),
                    )
                }
                checkVoice()
            }
        }.getOrNull()
    }

    private fun release() {
        val engine = tts ?: return
        tts = null
        ready = false
        runCatching { engine.stop() }
        runCatching { engine.shutdown() }
        onVoice(false)
    }

    /** The app's language as a tag ("fr", "pt-BR", "zh-Hant-TW"): the language the line is written in. */
    private fun languageTag(): String = app.resources.configuration.locales[0].toLanguageTag()

    /** The engine's voice for the app's language that is installed and needs no network, or null. */
    private fun voice(): android.speech.tts.Voice? {
        val engine = tts?.takeIf { ready } ?: return null
        val all = runCatching { engine.voices }.getOrNull()?.filterNotNull().orEmpty()
        val pick = SpokenAlertPolicy.pickVoice(
            all.map {
                SpokenAlertPolicy.Voice(
                    it.name, it.locale.language, it.locale.country, it.isNetworkConnectionRequired,
                    installed = it.features?.contains(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED) != true,
                )
            },
            languageTag(),
        ) ?: return null
        return all.firstOrNull { it.name == pick.name }
    }

    /** Tells [onVoice] whether the phone lacks a voice for the app's language (only once the engine has started). */
    fun checkVoice() {
        if (tts == null || !ready) return
        onVoice(voice() == null)
    }

    /** What [SpokenAlertPolicy] needs to know about the phone right now. */
    fun phone(dndOn: Boolean): SpokenAlertPolicy.Phone = SpokenAlertPolicy.Phone(
        dndOn = dndOn,
        ringerNormal = audio?.ringerMode == AudioManager.RINGER_MODE_NORMAL,
        // A call is ringing, going on, or being screened: nothing is said over it.
        inCall = audio?.mode != AudioManager.MODE_NORMAL,
        hasVoice = voice() != null,
    )

    /** Speaks [line] after whatever is being said. Nothing is logged, not even a failure. */
    fun say(line: String) {
        val engine = tts?.takeIf { ready } ?: return
        val v = voice() ?: return
        runCatching {
            engine.voice = v
            engine.speak(line, TextToSpeech.QUEUE_ADD, null, "coucou-alert")
        }
    }
}
