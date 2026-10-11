package com.coucou.android

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guards for the release build type. Gradle and R8 run only in CI (where `lint` now needs a release build, see verifyReleaseNoLogs), so
 * these read the build files and the sources for the rules that must not be lost by accident.
 */
class ReleaseBuildTest {
    private val gradle = File("build.gradle.kts").readText()
    private val rules = File("proguard-rules.pro").readText()
    private val main = File("src/main/kotlin")
    private fun sources() = main.walkTopDown().filter { it.extension == "kt" }.toList()

    @Test fun theReleaseTypeShrinksObfuscatesAndIsNotDebuggable() {
        val release = gradle.substringAfter("buildTypes {").substringBefore("buildFeatures")
        assertTrue(release.contains("isMinifyEnabled = true"))
        assertTrue(release.contains("isShrinkResources = true"))
        assertTrue(release.contains("isDebuggable = false"))
        assertTrue(release.contains("proguard-android-optimize.txt") && release.contains("\"proguard-rules.pro\""))
    }

    @Test fun signingComesFromTheEnvironmentOrGradlePropertiesNeverFromTheRepository() {
        for (name in listOf("COUCOU_KEYSTORE_FILE", "COUCOU_KEYSTORE_PASSWORD", "COUCOU_KEY_ALIAS", "COUCOU_KEY_PASSWORD")) assertTrue(name, gradle.contains("\"$name\""))
        assertTrue(gradle.contains("System.getenv(name) ?: providers.gradleProperty(name)"))
        // no literal password, no key file path, and never the debug key for a release
        assertFalse(Regex("""(storePassword|keyPassword)\s*=\s*"[^"]""").containsMatchIn(gradle))
        assertFalse(gradle.contains("signingConfigs.getByName(\"debug\")") || gradle.contains("signingConfigs[\"debug\"]"))
        assertTrue(gradle.contains("signingConfigs.findByName(\"release\")"))
    }

    @Test fun noKeyFileIsInTheRepositoryAndTheyAreIgnored() {
        val android = File("..")
        val found = android.walkTopDown().onEnter { it.name != "build" && it.name != ".gradle" && it.name != "node_modules" }
            // src/test/resources holds a throw-away certificate for the fake computer in the tests, not a signing key
            .filter { !it.path.replace('\\', '/').contains("src/test/resources") }.filter { it.isFile && it.extension in setOf("jks", "keystore", "p12", "pfx") }.toList()
        assertEquals("a signing key must never be in the repository: $found", emptyList<File>(), found)
        assertFalse(File("..").walkTopDown().onEnter { it.name != "build" && it.name != "node_modules" }.any { it.name == "keystore.properties" })
        val ignore = File("../.gitignore").readText()
        for (pattern in listOf("*.jks", "*.keystore", "*.p12", "keystore.properties")) assertTrue(pattern, ignore.lines().contains(pattern))
    }

    @Test fun everyLogCallIsRemovedFromTheReleaseAndCarriesNoSecret() {
        for (level in listOf("v", "d", "i", "w", "e")) assertTrue(level, rules.contains("public static int $level(...);"))
        assertTrue(rules.contains("-assumenosideeffects class android.util.Log"))
        val logLines = sources().flatMap { f -> f.readLines().filter { it.contains("Log.") && !it.trimStart().startsWith("import") && !it.trimStart().startsWith("//") }.map { f.name to it } }
        assertTrue("the test must see the log calls", logLines.size >= 10)
        for ((file, line) in logLines) {
            for (word in listOf("token", "secret", "fingerprint", "password", "command", "pairing", "access", "answer", "\${r.", "picks")) {
                assertFalse("$file logs '$word': $line", line.contains(word, ignoreCase = true))
            }
        }
    }

    @Test fun nothingElseWritesToTheLogOrTheConsole() {
        for (f in sources()) {
            val text = f.readText()
            assertFalse("${f.name}: println", Regex("""\bprintln\(""").containsMatchIn(text))
            assertFalse("${f.name}: printStackTrace", text.contains("printStackTrace"))
            assertFalse("${f.name}: System.out/err", text.contains("System.out") || text.contains("System.err"))
            assertFalse("${f.name}: a logging library", text.contains("Timber") || text.contains("android.util.Printer"))
        }
    }

    @Test fun theReleaseBuildIsProvedInCiWithoutTouchingTheWorkflow() {
        assertTrue(gradle.contains("tasks.matching { it.name == \"lint\" }.configureEach { dependsOn(verifyReleaseNoLogs) }"))
        assertTrue(gradle.contains("dependsOn(\"assembleRelease\")"))
        // the tags and messages that must not survive in the dex are the ones the sources use
        val tags = Regex("""(?<![A-Z_])TAG = "(\w+)"|Log\.\w\("(Coucou\w+)"""").findAll(sources().joinToString("\n") { it.readText() })
            .flatMap { m -> m.groupValues.drop(1).filter { it.isNotEmpty() } }.toSet()
        for (tag in tags) assertTrue("verifyReleaseNoLogs must look for $tag", gradle.contains("\"$tag\""))
    }

    @Test fun theRulesNeedNoKeepBecauseNothingIsReflected() {
        assertFalse(rules.lines().any { it.trim().startsWith("-keep ") || it.trim().startsWith("-keepclass") })
        for (f in sources()) {
            val text = f.readText()
            assertFalse("${f.name}: Class.forName", text.contains("Class.forName"))
            assertFalse("${f.name}: reflection", text.contains("getDeclaredMethod") || text.contains("getDeclaredField") || text.contains("kotlin.reflect"))
            assertFalse("${f.name}: getIdentifier", text.contains("getIdentifier("))
        }
    }
}
