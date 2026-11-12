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

    @Test fun theGeneratorKnowsTheSupportedLanguages() {
        assertEquals(listOf("fr", "es", "pt-BR", "zh-Hans", "hi", "bn", "ru", "id", "ar", "tr", "de", "ja", "ko", "zh-Hant", "th", "it"), table.map { it.first })
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
        assertEquals(Languages.SYSTEM, Languages.match("nl"))
        assertEquals(Languages.SYSTEM, Languages.match(""))
        assertEquals(Languages.SYSTEM, Languages.match(null))
    }

    @Test fun turkishRegionalLocalesSelectTurkish() {
        for (tag in listOf("tr", "tr-TR", "tr-CY", "tr_TR", "TR-tr")) {
            assertEquals(tag, "tr", Languages.match(tag))
        }
        assertEquals("Türkçe", Languages.ALL.single { it.tag == "tr" }.name)
    }

    @Test fun germanRegionalLocalesSelectGerman() {
        for (tag in listOf("de", "de-DE", "de-AT", "de-CH", "de_DE", "DE-de")) {
            assertEquals(tag, "de", Languages.match(tag))
        }
        assertEquals("Deutsch", Languages.ALL.single { it.tag == "de" }.name)
    }

    @Test fun japaneseRegionalLocalesSelectJapanese() {
        for (tag in listOf("ja", "ja-JP", "ja_JP", "JA-jp")) {
            assertEquals(tag, "ja", Languages.match(tag))
        }
        assertEquals("日本語", Languages.ALL.single { it.tag == "ja" }.name)
    }

    @Test fun koreanRegionalLocalesSelectKorean() {
        for (tag in listOf("ko", "ko-KR", "ko-KP", "ko_KR", "KO-kr")) {
            assertEquals(tag, "ko", Languages.match(tag))
        }
        assertEquals("한국어", Languages.ALL.single { it.tag == "ko" }.name)
    }

    @Test fun traditionalChineseLocalesSelectTraditionalChinese() {
        for (tag in listOf("zh-Hant", "zh-Hant-TW", "zh-TW", "zh-HK", "zh-MO", "zh_Hant_HK", "ZH-tw")) {
            assertEquals(tag, "zh-Hant", Languages.match(tag))
        }
        assertEquals("繁體中文", Languages.ALL.single { it.tag == "zh-Hant" }.name)
    }

    @Test fun simplifiedChineseAndBareChineseKeepSimplifiedChinese() {
        for (tag in listOf("zh", "zh-Hans", "zh-Hans-CN", "zh-CN", "zh-SG", "zh_CN", "ZH-cn")) {
            assertEquals(tag, "zh-Hans", Languages.match(tag))
        }
    }

    @Test fun anExplicitChineseScriptWinsOverTheRegion() {
        for (tag in listOf("zh-Hant-CN", "zh-Hant-SG", "zh_Hant_CN")) {
            assertEquals(tag, "zh-Hant", Languages.match(tag))
        }
        for (tag in listOf("zh-Hans-TW", "zh-Hans-HK", "zh-Hans-MO", "zh_Hans_TW")) {
            assertEquals(tag, "zh-Hans", Languages.match(tag))
        }
    }

    @Test fun chineseLocaleExtensionsDoNotBecomeScriptsOrRegions() {
        for (tag in listOf("zh-x-Hant-TW", "zh-CN-x-Hant-TW", "zh-u-rg-twzzzz")) {
            assertEquals(tag, "zh-Hans", Languages.match(tag))
        }
        assertEquals("zh-Hant", Languages.match("zh-TW-u-nu-hanidec"))
    }

    @Test fun thaiRegionalLocalesSelectThai() {
        for (tag in listOf("th", "th-TH", "th_TH", "TH-th")) {
            assertEquals(tag, "th", Languages.match(tag))
        }
        assertEquals("ภาษาไทย", Languages.ALL.single { it.tag == "th" }.name)
    }

    @Test fun italianRegionalLocalesSelectItalian() {
        for (tag in listOf("it", "it-IT", "it-CH", "it_IT", "IT-it")) {
            assertEquals(tag, "it", Languages.match(tag))
        }
        assertEquals("Italiano", Languages.ALL.single { it.tag == "it" }.name)
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
