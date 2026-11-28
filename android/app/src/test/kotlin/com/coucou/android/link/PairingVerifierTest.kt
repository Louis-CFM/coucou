package com.coucou.android.link

import java.io.File
import java.net.ServerSocket
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingVerifierTest {
    private val desktops = mutableListOf<FakeDesktop>()

    private fun startDesktop(): FakeDesktop = FakeDesktop(tls = true).also { desktops.add(it) }

    @After fun cleanup() {
        desktops.forEach { it.close() }
    }

    @Test fun validTlsAndTokenVerifiesPeerAndSendsBye() {
        val d = startDesktop()
        val p = PairingPayload("127.0.0.1", d.port, d.certSha256, d.expectedToken, "Test PC")

        val res = PairingVerifier.verifyWithConnector(PinnedTls.connector(p), p.token, "Pixel", timeoutMs = 3_000)

        assertEquals(PairingVerifier.Result.Verified("Test PC", "windows"), res)
        assertTrue(d.received.any { it.contains("\"type\":\"hello\"") })
    }

    @Test fun mismatchedCertificatePinIsRejected() {
        val d = startDesktop()
        val wrongFp = "00".repeat(32)
        val p = PairingPayload("127.0.0.1", d.port, wrongFp, d.expectedToken, "Spoofed PC")

        val res = PairingVerifier.verifyWithConnector(PinnedTls.connector(p), p.token, "Pixel", timeoutMs = 3_000)

        assertTrue(res is PairingVerifier.Result.Rejected)
    }

    @Test fun mismatchedTokenIsRejectedByPeer() {
        val d = startDesktop()
        val wrongToken = "Z".repeat(20)
        val p = PairingPayload("127.0.0.1", d.port, d.certSha256, wrongToken, "Test PC")

        val res = PairingVerifier.verifyWithConnector(PinnedTls.connector(p), p.token, "Pixel", timeoutMs = 3_000)

        assertTrue(res is PairingVerifier.Result.Rejected)
    }

    @Test fun closedSocketIsRejectedWithoutThrowing() {
        val closedPort = ServerSocket(0).use { it.localPort }
        val p = PairingPayload("127.0.0.1", closedPort, "aa".repeat(32), "T".repeat(20), "Dead PC")

        val res = PairingVerifier.verifyWithConnector(PinnedTls.connector(p), p.token, "Pixel", timeoutMs = 1_000)

        assertTrue(res is PairingVerifier.Result.Rejected)
    }

    @Test fun appModelVerifiesBeforeReplacingExistingPairing() {
        val modelSrc = File("src/main/kotlin/com/coucou/android/app/AppModel.kt").readText()
        val pairFn = modelSrc.substringAfter("fun pair(text: String): Boolean {").substringBefore("private fun connect(")
        val pairedBranch = pairFn.substringAfter("val gen = ++verifyGeneration")
        assertTrue(pairedBranch.contains("PairingVerifier.verify("))
        assertTrue(pairedBranch.contains("stopLink()"))
        assertTrue(pairedBranch.indexOf("PairingVerifier.verify(") < pairedBranch.indexOf("stopLink()"))
        assertTrue(pairedBranch.indexOf("PairingVerifier.verify(") < pairedBranch.indexOf("store.savePairing(p)"))
        assertTrue(pairedBranch.contains("msg_pair_verify_failed"))
    }
}
