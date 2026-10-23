package com.coucou.android.core

/**
 * The languages of the app: the BCP 47 tag, the name in the language itself (so a person can find it whatever the phone speaks) and whether it
 * is written right to left. [ALL] is what the picker offers; res/xml/locales_config.xml (Android's own per-app language screen) lists the same
 * tags, and a test checks that they match the translation files.
 */
object Languages {
    data class Language(val tag: String, val name: String)

    /** The empty tag: follow the phone. */
    const val SYSTEM = ""

    val ALL = listOf(
        Language("fr", "Français"),
        Language("es", "Español"),
        Language("pt-BR", "Português (Brasil)"),
        Language("zh-Hans", "简体中文"),
        Language("hi", "हिन्दी"),
        Language("bn", "বাংলা"),
        Language("ru", "Русский"),
        Language("id", "Bahasa Indonesia"),
        Language("ar", "العربية"),
    )

    /** The tag of the language that [tag] (as Android reports it, e.g. "zh-Hans-CN" or "pt-PT") stands for in the app; [SYSTEM] if there is none. */
    fun match(tag: String?): String {
        if (tag.isNullOrBlank()) return SYSTEM
        ALL.firstOrNull { it.tag.equals(tag, ignoreCase = true) }?.let { return it.tag }
        val language = tag.substringBefore('-').substringBefore('_').lowercase()
        return ALL.firstOrNull { it.tag.substringBefore('-').equals(language, ignoreCase = true) }?.tag ?: SYSTEM
    }
}
