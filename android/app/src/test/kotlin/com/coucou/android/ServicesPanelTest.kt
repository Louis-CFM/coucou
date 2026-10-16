package com.coucou.android

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ServicesPanelTest {
    private fun src(name: String) = File("src/main/kotlin/com/coucou/android/$name").readText()

    @Test fun theCardsAreReadOnly() {
        val p = src("ui/ServicesPanel.kt")
        assertFalse("nothing in a card can be tapped", p.contains("clickable") || p.contains("onClick") || p.contains("openUri"))
        assertFalse(p.contains("Log."))
    }

    @Test fun theyGoWhenTheLinkOrTheOfferDoes() {
        val m = src("app/AppModel.kt")
        assertTrue(m.substringAfter("private fun stopLink()").take(140).contains("services = emptyList()"))
        assertTrue(m.contains("if (Protocol.CAP_SERVICES !in caps) services = emptyList()"))
        assertFalse(m.substringAfter("override fun onServices").take(160).contains("kv.put"))
    }

    @Test fun homeShowsThemOnlyWhenThereAreSome() {
        assertTrue(src("MainActivity.kt").contains("if (model.services.isNotEmpty()) item"))
    }
}
