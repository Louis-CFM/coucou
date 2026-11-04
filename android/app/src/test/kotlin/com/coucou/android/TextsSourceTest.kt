package com.coucou.android

import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The English written next to a key in the code is the English of i18n/app-strings.json, so a translation always translates what the code says. */
class TextsSourceTest {
    private val source = JSONObject(File("../i18n/app-strings.json").readText())
    private val strings = source.getJSONObject("strings")
    private val plurals = source.getJSONObject("plurals")
    private fun unescape(s: String) = s.replace("\\$", "$").replace("\\\"", "\"").replace("\\\\", "\\")
    private val kotlinFiles = File("src/main/kotlin").walkTopDown().filter { it.extension == "kt" }.toList()
    private val lit = "\"((?:[^\"\\\\]|\\\\.)*)\""

    @Test fun everyTextInTheCodeIsInTheEnglishSourceWithTheSameWords() {
        var seen = 0
        for (f in kotlinFiles) {
            val text = f.readText()
            for (m in Regex("""Texts\.t\("([a-z0-9_]+)",\s*$lit""").findAll(text)) {
                seen++
                assertTrue("${f.name}: key ${m.groupValues[1]} is not in app-strings.json", strings.has(m.groupValues[1]))
                assertEquals("${f.name}: ${m.groupValues[1]}", strings.getString(m.groupValues[1]), unescape(m.groupValues[2]))
            }
            for (m in Regex("""Texts\.n\("([a-z0-9_]+)",\s*[^,]+,\s*$lit,\s*$lit""").findAll(text)) {
                seen++
                val p = plurals.optJSONObject(m.groupValues[1])
                assertTrue("${f.name}: plural ${m.groupValues[1]} is not in app-strings.json", p != null)
                assertEquals("${f.name}: ${m.groupValues[1]} one", p!!.getString("one"), unescape(m.groupValues[2]))
                assertEquals("${f.name}: ${m.groupValues[1]} other", p.getString("other"), unescape(m.groupValues[3]))
            }
            for (block in Regex("""private val \w+_ENGLISH = mapOf\(\n((?:.*\n)*?)\s*\)""").findAll(text)) {
                for (m in Regex(""""([a-z0-9_]+)" to $lit""").findAll(block.groupValues[1])) {
                    seen++
                    assertEquals("${f.name}: ${m.groupValues[1]}", strings.getString(m.groupValues[1]), unescape(m.groupValues[2]))
                }
            }
        }
        assertTrue("the guard found the texts ($seen)", seen > 60)
    }

    @Test fun noPureRuleKeepsAnEnglishSentenceOutOfTexts() {
        // The rules that make Home, the Widgets and the notification say something go through Texts.t / Texts.n.
        for (name in listOf("core/HomeText.kt", "core/Glance.kt", "core/ToolLabels.kt", "link/LinkHealth.kt")) {
            val text = File("src/main/kotlin/com/coucou/android/$name").readText()
            val code = text.lines().filterNot { it.trimStart().startsWith("*") || it.trimStart().startsWith("//") || it.trimStart().startsWith("/**") }
            for (line in code) {
                if (line.contains("Texts.") || line.contains("_ENGLISH") || line.trim().matches(Regex(""""[a-z0-9_]+" to .*"""))) continue
                assertTrue("$name keeps an English sentence in code: $line", !Regex("""(?<![\w.])"[A-Z][a-z]+ [a-z]+[^"]*"""").containsMatchIn(line))
            }
        }
    }

    @Test fun theTextsSourceReadsStaticReferencesSoTheShrinkerKeepsEveryString() {
        val lang = File("src/main/kotlin/com/coucou/android/app/AppLanguage.kt").readText()
        assertTrue(lang.contains("TextIds.strings[key]") && lang.contains("TextIds.plurals[key]"))
        assertTrue("no lookup by name", !lang.contains("getIdentifier"))
        val ids = File("src/main/kotlin/com/coucou/android/app/TextIds.kt").readText()
        for (k in strings.keys()) assertTrue("TextIds has $k", ids.contains("\"$k\" to R.string.$k,"))
        for (k in plurals.keys()) assertTrue("TextIds has plural $k", ids.contains("\"$k\" to R.plurals.$k,"))
        assertTrue(File("src/main/kotlin/com/coucou/android/app/CoucouApp.kt").readText().contains("Texts.source = AppLanguage.texts(this)"))
    }
}
