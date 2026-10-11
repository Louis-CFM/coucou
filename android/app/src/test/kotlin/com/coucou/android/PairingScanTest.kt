package com.coucou.android

import com.coucou.android.core.PairingScan
import com.coucou.android.core.ScanDecision
import com.coucou.android.core.ScanPermission
import com.coucou.android.core.ScanPermission.State
import com.coucou.android.link.PairingPayload
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingScanTest {
    private val fp = "ab".repeat(32)
    private val token = "T0ken_with-16plus_chars"
    private fun link(extra: String = "", v: String = "1", host: String = "192.168.1.20") =
        "coucou://pair?v=$v&host=$host&port=47821&fp=$fp&token=$token&name=My%20PC$extra"

    @Test fun aPairingLinkIsAccepted_andReturnedAsIs() {
        val d = PairingScan.decide(link()) as ScanDecision.Pairing
        assertEquals(link(), d.link)
        assertNotNull(PairingPayload.parse(d.link))
    }

    @Test fun surroundingWhitespaceIsTolerated() {
        assertTrue(PairingScan.decide("  \n${link()}\r\n ") is ScanDecision.Pairing)
    }

    @Test fun scanningAndPastingAgree() {
        // The same parser decides, so whatever pasting refuses a scan refuses too.
        val samples = listOf(
            link(), link(v = "2"), link(host = ""), "coucou://pair", "coucou://other?v=1", "https://example.com", "WIFI:S:home;T:WPA;P:secret;;",
            "", "   ", "coucou://pair?v=1&host=h&port=0&fp=$fp&token=$token", link().replace(fp, "zz"), link().replace(token, "short"),
        )
        for (s in samples) {
            val scanned = PairingScan.decide(s) is ScanDecision.Pairing
            assertEquals(s, PairingPayload.parse(s) != null, scanned)
        }
    }

    @Test fun otherCodesAreIgnored() {
        for (s in listOf(
            "https://coucou.example/pair?host=x", "BEGIN:VCARD", "12345", "mailto:a@b.c", "tel:+123", "http://192.168.1.20:47821",
            null, "", "coucou://pair/?", "COUCOU://PAIR?v=1",
        )) assertEquals(s, ScanDecision.NotPairing, PairingScan.decide(s))
    }

    @Test fun anAbsurdlyLongCodeIsNotALink() {
        assertEquals(ScanDecision.NotPairing, PairingScan.decide(link("&pad=" + "x".repeat(PairingScan.MAX_LINK))))
        assertNull(null as String?)
    }

    // ── camera permission ───────────────────────────────────────────────────────────────

    @Test fun grantedMeansScan_whateverElse() {
        for (asked in listOf(true, false)) for (explain in listOf(true, false)) assertEquals(State.GRANTED, ScanPermission.state(true, asked, explain))
    }

    @Test fun theFirstTimeWeAsk() {
        assertEquals(State.ASK, ScanPermission.state(false, askedBefore = false, canExplain = false))
    }

    @Test fun refusedOnceWeMayAskAgain() {
        assertEquals(State.ASK, ScanPermission.state(false, askedBefore = true, canExplain = true))
    }

    @Test fun refusedForGoodMeansSettingsOrPasting() {
        assertEquals(State.BLOCKED, ScanPermission.state(false, askedBefore = true, canExplain = false))
    }
}
