package com.coucou.android

import com.coucou.android.core.Languages
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The languages of the app: the picker, Android's own per-app language list, the resources and the build all list the same ones. */
class LanguagesTest {
    private fun read(path: String) = File(path).readText()

    /** The language table of the generator: tag, folder qualifier and name. */
    private val table = Regex("""\{ tag: "([^"]+)", qualifier: "([^"]+)", name: "([^"]+)", plural: \[([^\]]*)\] \}""")
        .findAll(read("../scripts/gen-strings.mjs")).map { Triple(it.groupValues[1], it.groupValues[2], it.groupValues[3]) }.toList()
    private val translations = File("../i18n/translations").listFiles { f -> f.extension == "json" }.orEmpty().map { it.nameWithoutExtension }.sorted()

    @Test fun theGeneratorKnowsNineLanguages() {
        assertEquals(listOf("fr", "es", "pt-BR", "zh-Hans", "hi", "bn", "ru", "id", "ar"), table.map { it.first })
    }

    @Test fun thePickerOffersExactlyTheLanguagesThatAreTranslated() {
        assertEquals(translations.sorted(), Languages.ALL.map { it.tag }.sorted())
        for (l in Languages.ALL) assertEquals(l.tag, table.first { it.first == l.tag }.third, l.name)
    }

    @Test fun androidsOwnLanguageListMatches() {
        val tags = Regex("""android:name="([^"]+)"""").findAll(read("src/main/res/xml/locales_config.xml")).map { it.groupValues[1] }.toList()
        assertEquals(listOf("en") + table.map { it.first }.filter { it in translations }, tags)
        assertTrue(read("src/main/AndroidManifest.xml").contains("""android:localeConfig="@xml/locales_config""""))
    }

    @Test fun theBuildKeepsEnglishAndEachTranslation() {
        val configured = Regex("""resourceConfigurations\s*\+=\s*listOf\(([^)]*)\)""").find(read("build.gradle.kts"))!!.groupValues[1]
            .split(",").map { it.trim().trim('"') }
        val expected = listOf("en") + table.filter { it.first in translations }.map { it.second }
        assertEquals(expected.sorted(), configured.sorted())
    }

    @Test fun everyTranslationHasItsFolderAndNothingElseIsThere() {
        val folders = File("src/main/res").listFiles().orEmpty().map { it.name }.filter { it.startsWith("values") }.sorted()
        val expected = (listOf("values", "values-notnight") + table.filter { it.first in translations }.map { "values-${it.second}" }).sorted()
        assertEquals(expected, folders)
        for (f in expected.filter { it != "values-notnight" }) assertTrue(f, File("src/main/res/$f/strings.xml").exists())
        // values-notnight is the light variant of the Widgets' colours, and holds colours only.
        assertEquals(listOf("colors.xml"), File("src/main/res/values-notnight").listFiles().orEmpty().map { it.name })
    }

    @Test fun englishIsTheSingleSourceOfTheKeys() {
        val english = Regex("""<(?:string|plurals) name="([a-z_0-9]+)"""").findAll(read("src/main/res/values/strings.xml")).map { it.groupValues[1] }.toSet()
        val source = read("../i18n/app-strings.json")
        val declared = Regex("""^ {4}"([a-z_0-9]+)":""", RegexOption.MULTILINE).findAll(source).map { it.groupValues[1] }.toSet()
        assertEquals(declared, english)
    }

    @Test fun theChoiceMapsToALanguageTheAppHas() {
        assertEquals("fr", Languages.match("fr"))
        assertEquals("fr", Languages.match("fr-CA"))
        assertEquals("pt-BR", Languages.match("pt-PT"))
        assertEquals("pt-BR", Languages.match("PT-br"))
        assertEquals(Languages.SYSTEM, Languages.match("de"))
        assertEquals(Languages.SYSTEM, Languages.match(""))
        assertEquals(Languages.SYSTEM, Languages.match(null))
    }

    @Test fun layoutsMirrorForRightToLeftLanguages() {
        assertTrue(read("src/main/AndroidManifest.xml").contains("""android:supportsRtl="true""""))
        // No layout or drawable says left or right: start and end mirror by themselves.
        for (dir in listOf("src/main/res/layout", "src/main/res/drawable")) for (f in File(dir).listFiles().orEmpty()) {
            val text = f.readText()
            for (attr in listOf("layout_marginLeft", "layout_marginRight", "paddingLeft", "paddingRight", "layout_alignParentLeft", "layout_alignParentRight", "drawableLeft", "drawableRight")) {
                assertFalse("${f.name} uses $attr", text.contains(attr))
            }
        }
        for (f in File("src/main/kotlin").walkTopDown().filter { it.extension == "kt" }) {
            val text = f.readText()
            for (bad in listOf("Alignment.Left", "Alignment.Right", "TextAlign.Left", "TextAlign.Right", "absolutePadding", "Arrangement.Left", "Arrangement.Right")) {
                assertFalse("${f.name} uses $bad", text.contains(bad))
            }
        }
    }
}
