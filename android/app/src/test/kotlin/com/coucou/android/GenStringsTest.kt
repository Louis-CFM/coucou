package com.coucou.android

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test

/**
 * The string generator, run on a small made-up project: it writes one folder per language and plurals, and --check refuses a translation
 * with a missing key, a wrong placeholder or a missing plural form, and a generated file that is stale. Needs Node (CI has it).
 */
class GenStringsTest {
    private val script = File("../scripts/gen-strings.mjs").absolutePath

    @Before fun needsNode() {
        val ok = runCatching { ProcessBuilder("node", "--version").redirectErrorStream(true).start().also { it.inputStream.readBytes() }.waitFor() == 0 }.getOrDefault(false)
        assumeTrue("Node is needed to run the generator", ok)
    }

    private class Result(val code: Int, val output: String)

    private fun run(root: File, vararg args: String): Result {
        val p = ProcessBuilder(listOf("node", script, "--root", root.path) + args).redirectErrorStream(true).start()
        val out = p.inputStream.bufferedReader().readText()
        return Result(p.waitFor(), out)
    }

    private fun project(
        fr: String = """{"strings": {"hello": "Bonjour %1${'$'}s", "bye": "Au revoir"}, "plurals": {"items": {"one": "%1${'$'}d élément", "many": "%1${'$'}d d'éléments", "other": "%1${'$'}d éléments"}}}""",
        extra: Map<String, String> = emptyMap(),
    ): File {
        val root = Files.createTempDirectory("gen-strings").toFile()
        File(root, "i18n/translations").mkdirs()
        File(root, "i18n/app-strings.json").writeText(
            """{"_about": "x", "strings": {"hello": "Hello %1${'$'}s", "bye": "Goodbye"}, "plurals": {"items": {"one": "%1${'$'}d item", "other": "%1${'$'}d items"}}}""",
        )
        File(root, "i18n/translations/fr.json").writeText(fr)
        for ((name, text) in extra) File(root, "i18n/translations/$name").writeText(text)
        return root
    }

    @Test fun itWritesAFolderPerLanguageWithItsPlurals() {
        val root = project()
        val r = run(root)
        assertEquals(r.output, 0, r.code)
        val fr = File(root, "app/src/main/res/values-fr/strings.xml").readText()
        assertTrue(fr.contains("""<string name="hello">Bonjour %1${'$'}s</string>"""))
        assertTrue(fr.contains("""<item quantity="many">%1${'$'}d d\'éléments</item>"""))
        val en = File(root, "app/src/main/res/values/strings.xml").readText()
        assertTrue(en.contains("""<item quantity="one">%1${'$'}d item</item>"""))
        assertEquals(listOf("en", "fr"), Regex("""android:name="([^"]+)"""").findAll(File(root, "app/src/main/res/xml/locales_config.xml").readText()).map { it.groupValues[1] }.toList())
        // The list of strings to check is generated too: without it the check says so.
        assertTrue(run(root, "--check").output.contains("stale: i18n/REVIEW.md"))
        assertEquals(0, run(root, "--review").code)
        assertEquals(0, run(root, "--check").code)
    }

    @Test fun aMissingKeyFailsTheCheck() {
        val root = project(fr = """{"strings": {"hello": "Bonjour %1${'$'}s"}, "plurals": {"items": {"one": "%1${'$'}d a", "many": "%1${'$'}d b", "other": "%1${'$'}d c"}}}""")
        val r = run(root, "--check")
        assertEquals(1, r.code)
        assertTrue(r.output, r.output.contains("""fr: missing string "bye""""))
    }

    @Test fun aWrongPlaceholderFailsTheCheck() {
        val root = project(fr = """{"strings": {"hello": "Bonjour %1${'$'}d", "bye": "Au revoir"}, "plurals": {"items": {"one": "%1${'$'}d a", "many": "%1${'$'}d b", "other": "%1${'$'}d c"}}}""")
        val r = run(root, "--check")
        assertEquals(1, r.code)
        assertTrue(r.output, r.output.contains(""""hello" has the placeholders"""))
    }

    @Test fun aMissingPluralFormFailsTheCheck() {
        val root = project(fr = """{"strings": {"hello": "Bonjour %1${'$'}s", "bye": "Au revoir"}, "plurals": {"items": {"one": "%1${'$'}d a", "other": "%1${'$'}d c"}}}""")
        val r = run(root, "--check")
        assertEquals(1, r.code)
        assertTrue(r.output, r.output.contains("""plural "items" has no "many" form"""))
    }

    @Test fun aPluralFormThatTheLanguageDoesNotUseFailsTheCheck() {
        val zh = """{"strings": {"hello": "你好 %1${'$'}s", "bye": "再见"}, "plurals": {"items": {"one": "%1${'$'}d 个", "other": "%1${'$'}d 个"}}}"""
        val r = run(project(extra = mapOf("zh-Hans.json" to zh)), "--check")
        assertEquals(1, r.code)
        assertTrue(r.output, r.output.contains("""has a "one" form that zh-Hans does not use"""))
    }

    @Test fun anExtraKeyAndAnUnknownLanguageFailTheCheck() {
        val extra = """{"strings": {"hello": "Bonjour %1${'$'}s", "bye": "Au revoir", "nope": "Non"}, "plurals": {"items": {"one": "%1${'$'}d a", "many": "%1${'$'}d b", "other": "%1${'$'}d c"}}}"""
        val r = run(project(fr = extra, extra = mapOf("xx.json" to "{}")), "--check")
        assertEquals(1, r.code)
        assertTrue(r.output, r.output.contains(""""nope" is not in app-strings.json"""))
        assertTrue(r.output, r.output.contains("xx.json: not a language"))
    }

    @Test fun aStaleGeneratedFileFailsTheCheck() {
        val root = project()
        run(root)
        File(root, "app/src/main/res/values-fr/strings.xml").appendText("<!-- edited by hand -->")
        val r = run(root, "--check")
        assertEquals(1, r.code)
        assertTrue(r.output, r.output.contains("stale: app/src/main/res/values-fr/strings.xml"))
    }

    @Test fun theReviewListsWhatWasNotTakenFromTheDesktopApps() {
        val root = project()
        val r = run(root, "--review")
        assertEquals(r.output, 0, r.code)
        val md = File(root, "i18n/REVIEW.md").readText()
        assertTrue(md.contains("## Français (fr)"))
        assertTrue(md.contains("`hello`, `bye`"))
    }
}
