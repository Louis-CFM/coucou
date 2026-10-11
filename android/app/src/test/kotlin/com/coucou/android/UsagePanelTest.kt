package com.coucou.android

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UsagePanelTest {
    private fun src(name: String) = File("src/main/kotlin/com/coucou/android/$name").readText()

    @Test fun everyBarSaysItsPercentageInWordsAndNotOnlyInColour() {
        val panel = src("ui/UsagePanel.kt")
        assertTrue(panel.contains("R.string.usage_pct"))
        assertTrue(panel.contains("R.string.usage_desc"))
    }

    @Test fun nothingIsLoggedOrStoredAndItGoesWhenTheLinkOrTheOfferDoes() {
        assertFalse(src("ui/UsagePanel.kt").contains("Log."))
        val model = src("app/AppModel.kt")
        assertTrue(model.substringAfter("private fun stopLink()").take(100).contains("usage = null"))
        assertTrue(model.contains("if (Protocol.CAP_USAGE !in caps) usage = null"))
        assertFalse(model.substringAfter("override fun onUsage").take(300).contains("kv.put"))
    }

    @Test fun homeShowsThePanelOnlyWhenThereIsUsage() {
        assertTrue(src("MainActivity.kt").contains("if (model.usage != null) item"))
    }
}
