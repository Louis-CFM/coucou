package com.coucou.android

import com.coucou.android.core.Texts
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test

class TextsTest {
    @After fun clean() { Texts.source = null }

    @Test fun englishIsTheFallback() {
        assertEquals("Running a command", Texts.t("tool_running", "Running a command"))
        assertEquals("Allowed: edit files", Texts.t("home_recent_allowed", "Allowed: %1\$s", "edit files"))
        assertEquals("1 request to approve", Texts.n("glance_requests", 1, "%1\$d request to approve", "%1\$d requests to approve"))
        assertEquals("3 requests to approve", Texts.n("glance_requests", 3, "%1\$d request to approve", "%1\$d requests to approve"))
    }

    @Test fun aSourceWins() {
        Texts.source = object : Texts.Source {
            override fun string(key: String) = if (key == "tool_running") "Exécute une commande" else null
            override fun plural(key: String, count: Int) = if (key == "glance_requests") (if (count == 1) "%1\$d demande" else "%1\$d demandes") else null
        }
        assertEquals("Exécute une commande", Texts.t("tool_running", "Running a command"))
        assertEquals("Elsewhere", Texts.t("other", "Elsewhere"))
        assertEquals("2 demandes", Texts.n("glance_requests", 2, "%1\$d request to approve", "%1\$d requests to approve"))
        assertEquals("1 request", Texts.n("another", 1, "%1\$d request", "%1\$d requests"))
    }

    @Test fun argumentsAreFilledByPosition() {
        Texts.source = object : Texts.Source {
            override fun string(key: String) = "%2\$s a autorisé %1\$s"
            override fun plural(key: String, count: Int): String? = null
        }
        assertEquals("Marie a autorisé Claude", Texts.t("k", "%1\$s was allowed by %2\$s", "Claude", "Marie"))
    }

    @Test fun aTextWithAPercentSignButNoArgumentIsNotFormatted() {
        assertEquals("100% done", Texts.t("k", "100% done"))
    }
}
