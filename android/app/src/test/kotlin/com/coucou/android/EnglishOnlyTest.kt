package com.coucou.android

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The app is English only, whatever the phone's language is. */
class EnglishOnlyTest {
    private fun read(path: String) = File(path).readText()

    @Test fun theBuildKeepsOnlyEnglishResources() {
        val gradle = read("build.gradle.kts")
        assertTrue(Regex("""resourceConfigurations\s*\+=\s*listOf\("en"\)""").containsMatchIn(gradle))
    }

    @Test fun thereIsNoLanguageChoiceAnywhere() {
        assertFalse(read("src/main/AndroidManifest.xml").contains("localeConfig"))
        assertFalse(File("src/main/res/xml/locales_config.xml").exists())
        assertFalse(File("src/main/kotlin/com/coucou/android/core/Languages.kt").exists())
        val settings = read("src/main/kotlin/com/coucou/android/ui/SettingsScreens.kt")
        assertFalse(settings.contains("LocaleManager"))
        assertFalse(settings.contains("applicationLocales"))
    }

    @Test fun englishStringsAreTheSingleSourceOfTruth() {
        val source = read("../i18n/app-strings.json")
        val english = Regex("""name="([a-z_0-9]+)"""").findAll(read("src/main/res/values/strings.xml")).map { it.groupValues[1] }.toSet()
        val declared = Regex("""^\s{4}"([a-z_0-9]+)":""", RegexOption.MULTILINE).findAll(source.substringAfter(""""strings"""")).map { it.groupValues[1] }.toSet()
        assertEquals(declared, english)
    }

    @Test fun thereAreNoOtherLanguagesInTheRepo() {
        val folders = File("src/main/res").listFiles().orEmpty().map { it.name }.filter { it.startsWith("values") }
        assertEquals(listOf("values"), folders.sorted())
        assertFalse(File("../i18n/extra.json").exists())
    }
}
