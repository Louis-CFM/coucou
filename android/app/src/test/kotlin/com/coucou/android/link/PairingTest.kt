package com.coucou.android.link

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.security.cert.CertificateException

class PairingTest {
    private val fp = "ab".repeat(32)
    private val token = "A1b2C3d4E5f6G7h8I9j0"
    private val good = "coucou://pair?v=1&host=192.168.1.20&port=47821&fp=$fp&token=$token&name=My%20PC"

    @Test fun parsesAWellFormedLink() {
        val p = PairingPayload.parse(good)!!
        assertEquals("192.168.1.20", p.host)
        assertEquals(47821, p.port)
        assertEquals(fp, p.certSha256)
        assertEquals(token, p.token)
        assertEquals("My PC", p.desktopName)
    }

    @Test fun toleratesSurroundingWhitespace() {
        assertNotNull(PairingPayload.parse("  $good\n"))
    }

    @Test fun rejectsEverythingElse() {
        val bad = listOf(
            "", "https://pair?v=1", "coucou://other?v=1&host=h&port=1&fp=$fp&token=$token",
            good.replace("v=1", "v=2"), good.replace("port=47821", "port=0"), good.replace("port=47821", "port=70000"),
            good.replace("port=47821", "port=abc"), good.replace("fp=$fp", "fp=short"), good.replace("host=192.168.1.20&", ""),
            good.replace("token=$token", "token=short"), good.replace("token=$token", "token=${"a".repeat(129)}"),
            good.replace("token=$token", "token=bad%20chars%21%21%21%21%21%21"),
        )
        for (b in bad) assertNull(b, PairingPayload.parse(b))
    }

    @Test fun uppercaseFingerprintIsNormalised() {
        assertEquals(fp, PairingPayload.parse(good.replace(fp, fp.uppercase()))!!.certSha256)
    }

    @Test fun pinnedTrustManagerRejectsNonMatchingAndEmptyChains() {
        val tm = PinnedTrustManager(fp)
        try { tm.checkServerTrusted(emptyArray(), "ECDHE_ECDSA"); fail("empty chain accepted") } catch (_: CertificateException) { }
        try { tm.checkServerTrusted(null, "ECDHE_ECDSA"); fail("null chain accepted") } catch (_: CertificateException) { }
        try { tm.checkClientTrusted(emptyArray(), "x"); fail("client certs accepted") } catch (_: CertificateException) { }
        assertTrue(tm.acceptedIssuers.isEmpty())
    }
}
