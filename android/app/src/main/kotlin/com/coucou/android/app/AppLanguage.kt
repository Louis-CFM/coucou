package com.coucou.android.app

import android.app.Activity
import android.app.LocaleManager
import android.content.Context
import android.content.res.Configuration
import android.content.res.Resources
import android.os.Build
import android.os.LocaleList
import com.coucou.android.core.Languages
import com.coucou.android.core.Texts
import java.util.Locale

/**
 * The language of the app: the phone's own, or one of [Languages.ALL]. On Android 13 and later the choice is Android's per-app language
 * (LocaleManager), so it also shows in Android's own settings (Apps, Coucou for Android, Language). On Android 11 and 12 there is no such
 * thing, so the choice is kept in the app and applied to the app's resources (and to the activity when it starts).
 */
object AppLanguage {
    private const val PREFS = "coucou_ui"
    private const val KEY = "app_language"

    /** The language in force: a tag of [Languages.ALL], or [Languages.SYSTEM] for the phone's own. */
    fun current(context: Context): String =
        if (Build.VERSION.SDK_INT >= 33) {
            val locales = context.getSystemService(LocaleManager::class.java).applicationLocales
            if (locales.isEmpty) Languages.SYSTEM else Languages.match(locales[0].toLanguageTag())
        } else {
            Languages.match(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, ""))
        }

    /** Chooses [tag] ([Languages.SYSTEM] for the phone's own). An activity is recreated so its text changes at once. */
    fun set(context: Context, tag: String) {
        val language = Languages.match(tag)
        if (Build.VERSION.SDK_INT >= 33) {
            // The system saves the choice, shows it in its own settings and restarts the activity with the new language.
            context.getSystemService(LocaleManager::class.java).applicationLocales =
                if (language.isEmpty()) LocaleList.getEmptyLocaleList() else LocaleList.forLanguageTags(language)
        } else {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY, language).apply()
            applyToApp(context.applicationContext)
            (context as? Activity)?.recreate()
        }
    }

    /** Before Android 13: the context an activity or the application is built on, in the language chosen. Later: unchanged. */
    fun wrap(base: Context): Context {
        if (Build.VERSION.SDK_INT >= 33) return base
        val language = current(base)
        if (language.isEmpty()) return base
        val locale = Locale.forLanguageTag(language)
        Locale.setDefault(locale)
        val config = Configuration(base.resources.configuration).apply { setLocale(locale); setLayoutDirection(locale) }
        return base.createConfigurationContext(config)
    }

    /** Before Android 13: puts the language in force in the application's resources (they are shared by what the app builds text with). */
    private fun applyToApp(app: Context) {
        val language = current(app)
        val locale = if (language.isEmpty()) Resources.getSystem().configuration.locales[0] else Locale.forLanguageTag(language)
        Locale.setDefault(locale)
        val config = Configuration(app.resources.configuration).apply { setLocale(locale); setLayoutDirection(locale) }
        @Suppress("DEPRECATION")
        app.resources.updateConfiguration(config, app.resources.displayMetrics)
    }

    /** The texts of the pure rules ([Texts]), looked up in the string resources of the application, in whatever language is in force. */
    fun texts(app: Context): Texts.Source = object : Texts.Source {
        override fun string(key: String): String? = TextIds.strings[key]?.let { app.resources.getString(it) }
        override fun plural(key: String, count: Int): String? = TextIds.plurals[key]?.let { app.resources.getQuantityString(it, count) }
    }
}
