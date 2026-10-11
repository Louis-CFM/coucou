package com.coucou.android.link

import java.net.ServerSocket
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** "Can't connect?": every check against a fake computer and fake network sources. */
class DiagnosticsTest {
    private val closeables = mutableListOf<AutoCloseable>()
    @After fun cleanup() = closeables.forEach { runCatching { it.close() } }
    private fun <T : AutoCloseable> T.track(): T { closeables.add(this); return this }

    private val token = "T".repeat(20)
    private fun pairing(d: FakeDesktop, fp: String = d.certSha256, tok: String = token, host: String = "127.0.0.1") =
        PairingPayload(host, d.port, fp, tok, "My private PC name")

    private fun env(
        p: PairingPayload, wifi: Boolean = true, cellular: Boolean = false, found: List<Found> = emptyList(),
        relay: (() -> DiagResult)? = null,
    ) = LanDiagnostics(p, { wifi }, { cellular }, { found }, PinnedTls.connector(p), relay, timeoutMs = 1_500)

    private fun results(e: DiagEnv) = Diagnostics.run(e).toMap()

    @Test fun everythingGreenWhenTheComputerIsThereAndPaired() {
        val d = FakeDesktop(tls = true).track()
        val p = pairing(d)
        val found = listOf(Found("PC", "127.0.0.1", d.port, Discovery.fingerprintId(d.certSha256), Discovery.TXT_VERSION))
        val r = results(env(p, found = found))
        for (step in listOf(DiagStep.NETWORK, DiagStep.ADDRESS, DiagStep.DISCOVERY, DiagStep.SECURE, DiagStep.TOKEN)) assertTrue("$step: ${r[step]}", r[step] is DiagResult.Ok)
        assertFalse(r.containsKey(DiagStep.RELAY))
    }

    @Test fun noWifiMeansTheLaterLocalStepsAreSkippedNotGuessed() {
        val d = FakeDesktop(tls = true).track()
        val r = results(env(pairing(d), wifi = false))
        assertTrue(r[DiagStep.NETWORK] is DiagResult.Problem)
        assertTrue(r[DiagStep.ADDRESS] is DiagResult.Skipped)
        assertTrue(r[DiagStep.DISCOVERY] is DiagResult.Skipped)
        assertTrue(r[DiagStep.SECURE] is DiagResult.Skipped)
        assertTrue(r[DiagStep.TOKEN] is DiagResult.Skipped)
    }

    @Test fun mobileDataIsFineWhenThePairingHasARelay() {
        val d = FakeDesktop(tls = true).track()
        val relay = RelayPairing("wss://relay.example.com", RelayCrypto.base64UrlEncode(ByteArray(16)), RelayCrypto.base64UrlEncode(ByteArray(32)), RelayCrypto.base64UrlEncode(ByteArray(32)))
        val e = env(pairing(d).copy(relay = relay), wifi = false, cellular = true, relay = { DiagResult.Ok("The relay answers") })
        val r = results(e)
        assertTrue(r[DiagStep.NETWORK] is DiagResult.Ok)
        assertEquals(DiagResult.Ok("The relay answers"), r[DiagStep.RELAY])
    }

    @Test fun aClosedPortIsAnAddressProblemAndStopsTheSecureSteps() {
        val closed = ServerSocket(0).use { it.localPort }
        val p = PairingPayload("127.0.0.1", closed, "ab".repeat(32), token, "PC")
        val r = results(env(p))
        val a = r[DiagStep.ADDRESS] as DiagResult.Problem
        assertTrue(a.problem.contains("127.0.x.x"))
        assertTrue(r[DiagStep.SECURE] is DiagResult.Skipped)
        assertTrue(r[DiagStep.TOKEN] is DiagResult.Skipped)
    }

    @Test fun anotherCertificateIsNamedAsSuchAndTheTokenIsNeverSent() {
        val d = FakeDesktop(tls = true).track()
        val r = results(env(pairing(d, fp = "00".repeat(32))))
        val s = r[DiagStep.SECURE] as DiagResult.Problem
        assertTrue(s.problem.contains("not the computer you paired with"))
        assertTrue(r[DiagStep.TOKEN] is DiagResult.Skipped)
        assertTrue("no hello reached the computer", d.received.none { it.contains("hello") })
    }

    @Test fun aWrongPairingCodeIsToldApartFromEverythingElse() {
        val d = FakeDesktop(tls = true).track()
        val r = results(env(pairing(d, tok = "W".repeat(20))))
        assertTrue(r[DiagStep.SECURE] is DiagResult.Ok)
        val t = r[DiagStep.TOKEN] as DiagResult.Problem
        assertTrue(t.problem.contains("pairing code was refused"))
    }

    @Test fun aComputerThatSpeaksAnotherVersionIsToldApart() {
        val d = FakeDesktop(tls = true).track()
        d.welcomeVersion = 2
        val t = results(env(pairing(d)))[DiagStep.TOKEN] as DiagResult.Problem
        assertTrue(t.problem.contains("version 2"))
    }

    @Test fun discoveryTellsAMovedComputerFromAMissingOne() {
        val d = FakeDesktop(tls = true).track()
        val p = pairing(d)
        val id = Discovery.fingerprintId(d.certSha256)
        val moved = listOf(Found("PC", "192.168.7.7", 47821, id, Discovery.TXT_VERSION))
        assertTrue((results(env(p, found = moved))[DiagStep.DISCOVERY] as DiagResult.Problem).problem.contains("192.168.x.x"))
        assertTrue((results(env(p, found = emptyList()))[DiagStep.DISCOVERY] as DiagResult.Problem).problem.contains("not announcing"))
        val lookalike = listOf(Found("PC", "192.168.7.7", 47821, "deadbeef", Discovery.TXT_VERSION))
        assertTrue("another computer's announcement does not count", results(env(p, found = lookalike))[DiagStep.DISCOVERY] is DiagResult.Problem)
    }

    @Test fun aCheckThatThrowsBecomesAProblemNotACrash() {
        val broken = object : DiagEnv {
            override fun network() = DiagResult.Ok("ok")
            override fun address(): DiagResult = error("boom")
            override fun discovery() = DiagResult.Ok("ok")
            override fun secure() = DiagResult.Ok("ok")
            override fun token() = DiagResult.Ok("ok")
            override fun relay(): DiagResult? = null
        }
        val r = Diagnostics.run(broken).toMap()
        assertTrue((r[DiagStep.ADDRESS] as DiagResult.Problem).problem.contains("IllegalStateException"))
        assertTrue(r[DiagStep.SECURE] is DiagResult.Skipped)
    }

    @Test fun theReportNeverContainsASecretTheNameOrTheFullAddress() {
        val d = FakeDesktop(tls = true).track()
        val p = pairing(d, host = "192.168.1.20")
        val fakeAddress = Diagnostics.maskHost(p.host)
        assertEquals("192.168.x.x", fakeAddress)
        assertEquals("a name (hidden)", Diagnostics.maskHost("my-pc.local"))
        val results = Diagnostics.run(env(p.copy(host = "127.0.0.1")).also { }, { _, _ -> })
        val text = Diagnostics.report("0.1.0", "13", "SM-A127F", results, fakeAddress, "relay")
        for (secret in listOf(token, p.certSha256, p.desktopName, "192.168.1.20", "127.0.0.1")) assertFalse("report mentions $secret", text.contains(secret))
        assertTrue(text.startsWith("Coucou for Android 0.1.0 · Android 13 · SM-A127F"))
        assertTrue(text.contains("Computer: 192.168.x.x · connected via: relay"))
        assertTrue(text.lines().drop(2).all { it.startsWith("OK ") || it.startsWith("PROBLEM ") || it.startsWith("SKIPPED ") })
    }

    @Test fun theStepsRunInOrderAndEachIsReportedAsItFinishes() {
        val d = FakeDesktop(tls = true).track()
        val seen = mutableListOf<DiagStep>()
        Diagnostics.run(env(pairing(d))) { step, _ -> seen += step }
        assertEquals(listOf(DiagStep.NETWORK, DiagStep.ADDRESS, DiagStep.DISCOVERY, DiagStep.SECURE, DiagStep.TOKEN), seen)
    }

    @Test fun theSourceNeverPutsThePairingCodeInAResult() {
        val src = java.io.File("src/main/kotlin/com/coucou/android/link/Diagnostics.kt").readText()
        // The token is only ever read to build the hello; no result string interpolates it, and nothing logs.
        assertEquals(1, Regex("""p\.token""").findAll(src).count())
        assertFalse(src.contains("Log.") || src.contains("println"))
        assertFalse(Regex("""DiagResult\.\w+\([^)]*\$\{?p\.(token|certSha256)""").containsMatchIn(src))
    }
}
