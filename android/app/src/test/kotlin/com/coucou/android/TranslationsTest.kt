package com.coucou.android

import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Every language has every string, with the same placeholders and the plural forms its rule needs; nothing is left in English by mistake. */
class TranslationsTest {
    private val source = JSONObject(File("../i18n/app-strings.json").readText())
    private val english = source.getJSONObject("strings")
    private val englishPlurals = source.getJSONObject("plurals")
    private val files = File("../i18n/translations").listFiles { f -> f.extension == "json" }!!.sortedBy { it.name }
    private fun placeholders(s: String) = Regex("""%(?:\d+\$)?[sd%]""").findAll(s).map { it.value }.sorted().toList()
    private val categories = mapOf(
        "fr" to listOf("one", "many", "other"), "es" to listOf("one", "many", "other"), "pt-BR" to listOf("one", "many", "other"),
        "zh-Hans" to listOf("other"), "hi" to listOf("one", "other"), "bn" to listOf("one", "other"),
        "ru" to listOf("one", "few", "many", "other"), "id" to listOf("other"), "ar" to listOf("zero", "one", "two", "few", "many", "other"),
    )

    @Test fun thereIsAtLeastOneLanguage() = assertTrue(files.isNotEmpty())

    @Test fun everyLanguageHasEveryStringWithTheSamePlaceholders() {
        for (f in files) {
            val t = JSONObject(f.readText()).getJSONObject("strings")
            for (k in english.keys()) {
                assertTrue("${f.name}: missing $k", t.has(k) && t.getString(k).isNotBlank())
                assertEquals("${f.name}: $k", placeholders(english.getString(k)), placeholders(t.getString(k)))
            }
            for (k in t.keys()) assertTrue("${f.name}: $k is not in the English source", english.has(k))
        }
    }

    @Test fun everyLanguageHasEveryPluralWithItsForms() {
        for (f in files) {
            val p = JSONObject(f.readText()).getJSONObject("plurals")
            val needed = categories.getValue(f.nameWithoutExtension)
            for (k in englishPlurals.keys()) {
                assertTrue("${f.name}: missing plural $k", p.has(k))
                val forms = p.getJSONObject(k)
                assertEquals("${f.name}: $k", needed.sorted(), forms.keys().asSequence().toList().sorted())
                for (c in needed) assertEquals("${f.name}: $k $c", placeholders(englishPlurals.getJSONObject(k).getString("other")), placeholders(forms.getString(c)))
            }
        }
    }

    @Test fun onlyNamesNumbersAndShortWordsStayAsTheyAreInEnglish() {
        val allowed = setOf(
            "about_repo", "widget_initial_title", "widget_initial_count", "widget_sample_claude", "widget_sample_claude_short", "widget_sample_codex",
            "widget_sample_gemini", "widget_sample_one", "widget_sample_today", "widget_sample_pct_a", "widget_sample_pct_b", "widget_sample_ring_pct",
            "widget_sample_ring_label", "usage_claude", "usage_codex", "widget_pill_cd", "chat_count", "files_counts", "usage_window_5h", "ago_minutes",
            "ago_hours", "ago_hours_minutes", "widget_btn_chat", "chat_model", "app_name", "tab_chat", "chat_title", "settings_volume", "question_ok", "diag_ok", "agent_kind",
            "wardrobe_auto_tag", "usage_pct", "tool_a_file", "widget_mochi_description", "widget_sample_two_waiting",
            // The same word in the language (French "Licences", "Services", "Standard").
            "licences_title", "services_title", "vibration_standard", "recap_sessions",
        )
        for (f in files) {
            val t = JSONObject(f.readText()).getJSONObject("strings")
            val same = english.keys().asSequence().filter { t.getString(it) == english.getString(it) }.toList()
            for (k in same) assertTrue("${f.name}: $k is still the English text", k in allowed || english.getString(k).length <= 5)
        }
    }

    @Test fun theGeneratorAcceptsThemAll() {
        val ok = runCatching { ProcessBuilder("node", "--version").redirectErrorStream(true).start().also { it.inputStream.readBytes() }.waitFor() == 0 }.getOrDefault(false)
        assumeTrue("Node is needed to run the generator", ok)
        val p = ProcessBuilder("node", File("../scripts/gen-strings.mjs").absolutePath, "--check").redirectErrorStream(true).start()
        val out = p.inputStream.bufferedReader().readText()
        assertEquals(out, 0, p.waitFor())
    }

    @Test fun theReviewFileListsWhatIsNotTheDesktopAppsOwnWording() {
        val review = File("../i18n/REVIEW.md")
        if (!review.exists()) return
        val text = review.readText()
        for (f in files) assertTrue("${f.name} is in REVIEW.md", text.contains("(${f.nameWithoutExtension})"))
        assertFalse(text.contains("TODO"))
    }
}
