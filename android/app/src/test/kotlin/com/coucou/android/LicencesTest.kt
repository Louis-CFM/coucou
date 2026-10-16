package com.coucou.android

import com.coucou.android.core.Licences
import com.coucou.android.core.Nav
import com.coucou.android.core.Screen
import com.coucou.android.core.Tab
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Settings > About > Licences: the texts that ship are the real ones, every library in the build is covered, and the screen is reachable. */
class LicencesTest {
    private fun asset(name: String) = File("src/main/assets/licenses/$name").readText()
    private fun src(name: String) = File("src/main/kotlin/com/coucou/android/$name").readText()

    @Test fun theMitTextIsTheRepositorysLicenceFileWord_for_word() {
        assertEquals(ReferenceFiles.file("LICENSE").readText(), asset("MIT.txt"))
        assertTrue(asset("MIT.txt").contains("Copyright (c) 2026 Louis Raillé"))
        assertTrue(asset("MIT.txt").contains("Permission is hereby granted, free of charge"))
        assertTrue(asset("MIT.txt").contains("THE SOFTWARE IS PROVIDED \"AS IS\""))
    }

    @Test fun theApacheTextIsTheWholeLicence() {
        val a = asset("Apache-2.0.txt")
        for (part in listOf(
            "Apache License", "Version 2.0, January 2004", "TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION", "1. Definitions.",
            "Grant of Copyright License", "Grant of Patent License", "Redistribution.", "Disclaimer of Warranty", "Limitation of Liability",
            "END OF TERMS AND CONDITIONS", "APPENDIX: How to apply the Apache License to your work.",
        )) assertTrue("missing: $part", a.contains(part))
    }

    @Test fun theNoticesNameWhoOwnsWhatAndTheArtworkIsNotMit() {
        val n = asset("NOTICES.txt")
        assertTrue(n.contains("part of Coucou by Louis Raillé"))
        assertTrue(n.contains("https://github.com/Louis-CFM/coucou"))
        assertTrue(n.contains("released under the MIT License"))
        assertTrue(n.contains("NOT covered by the MIT License"))
        assertTrue(n.contains("LICENSE-ASSETS.md"))
        assertTrue(n.contains("written permission"))
        assertTrue(n.contains("ZXing Core 3.5.3") && n.contains("Apache License, Version 2.0"))
        assertTrue(n.contains("Android Open Source Project") && n.contains("JetBrains"))
    }

    @Test fun theZxingVersionInTheNoticeIsTheOneInTheBuild() {
        val v = Regex("""com\.google\.zxing:core:([0-9.]+)""").find(File("build.gradle.kts").readText())!!.groupValues[1]
        assertTrue("NOTICES.txt names ZXing Core $v", asset("NOTICES.txt").contains("ZXing Core $v"))
    }

    @Test fun everyLibraryInTheBuildIsCoveredByANotice() {
        val groups = Regex("""implementation\("([^":]+):""").findAll(File("build.gradle.kts").readText()).map { it.groupValues[1] }.toSet()
        val covered = setOf("androidx.activity", "androidx.lifecycle", "androidx.compose.material3", "androidx.compose.ui", "androidx.camera", "com.google.zxing")
        assertEquals("a new dependency needs a line in NOTICES.txt and in this list", covered, groups)
    }

    @Test fun theScreenShowsTheThreeFilesInOrder() {
        assertEquals(listOf("NOTICES.txt", "MIT.txt", "Apache-2.0.txt"), Licences.FILES)
        for (f in Licences.FILES) assertTrue("$f is bundled", File("src/main/assets/licenses/$f").length() > 500)
        val text = Licences.FILES.joinToString("\n\n") { asset(it) }
        val p = Licences.paragraphs(text)
        assertTrue(p.size > 50)
        assertTrue(p.none { it.isBlank() })
        // nothing is lost by cutting it into blocks
        assertEquals(text.filterNot { it.isWhitespace() }, p.joinToString("").filterNot { it.isWhitespace() })
    }

    @Test fun licencesIsOneTapFromAboutAndBackGoesToSettings() {
        assertEquals(Screen.SETTINGS, Nav.back(Screen.LICENCES))
        assertEquals(Tab.SETTINGS, Nav.tabOf(Screen.LICENCES))
        assertFalse(Nav.barVisible(Screen.LICENCES, false))
        val settings = src("ui/SettingsScreens.kt")
        assertTrue(settings.substringAfter("settings_section_about").contains("LinkRow(stringResource(R.string.licences_title), onLicences)"))
        assertTrue(src("MainActivity.kt").contains("Screen.LICENCES -> LicencesScreen("))
        // it reads the bundled files and says nothing of its own
        assertTrue(src("ui/LicencesScreen.kt").contains("licenses/\$name"))
    }
}
