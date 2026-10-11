package com.coucou.android.link

import java.io.File
import java.net.InetAddress
import java.security.KeyStore
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLServerSocket
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * The rule that matters most: a lookalike on the network cannot get the token. These tests run real TLS on the loopback
 * with two throwaway self-signed certificates (made with the JDK's keytool; skipped where it is missing).
 */
class PinnedProbeTest {
    private class Server(val sha256: String, val socket: SSLServerSocket) {
        /** Bytes of application data this server received after the handshake: the token would be in them. */
        val received = AtomicInteger()
        @Volatile var handshakes = 0
        val thread = Thread {
            try {
                while (true) {
                    val c = socket.accept()
                    try {
                        (c as javax.net.ssl.SSLSocket).startHandshake()
                        handshakes++
                        c.soTimeout = 400
                        val buf = ByteArray(256)
                        while (true) { val n = c.getInputStream().read(buf); if (n < 0) break; received.addAndGet(n) }
                    } catch (_: Exception) {
                    } finally { runCatching { c.close() } }
                }
            } catch (_: Exception) {
            }
        }.apply { isDaemon = true; start() }
        val port get() = socket.localPort
        fun close() = runCatching { socket.close() }
    }

    private fun server(dir: File, alias: String): Server? {
        val file = File(dir, "$alias.p12")
        val p = runCatching {
            ProcessBuilder(
                "keytool", "-genkeypair", "-alias", alias, "-keyalg", "EC", "-groupname", "secp256r1", "-dname", "CN=$alias",
                "-validity", "3650", "-storetype", "PKCS12", "-keystore", file.path, "-storepass", "changeit", "-keypass", "changeit",
            ).redirectErrorStream(true).start()
        }.getOrNull() ?: return null
        p.inputStream.readBytes()
        if (p.waitFor() != 0) return null
        val ks = KeyStore.getInstance("PKCS12").apply { file.inputStream().use { load(it, "changeit".toCharArray()) } }
        val sha = MessageDigest.getInstance("SHA-256").digest(ks.getCertificate(alias).encoded).joinToString("") { "%02x".format(it) }
        val kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply { init(ks, "changeit".toCharArray()) }
        val ctx = SSLContext.getInstance("TLS").apply { init(kmf.keyManagers, null, null) }
        val ss = ctx.serverSocketFactory.createServerSocket(0, 5, InetAddress.getByName("127.0.0.1")) as SSLServerSocket
        return Server(sha, ss)
    }

    private fun dir() = java.nio.file.Files.createTempDirectory("coucou-probe").toFile()

    @Test fun theRealComputerPassesAndALookalikeDoesNot() {
        val d = dir()
        val real = server(d, "real"); val fake = server(d, "fake")
        assumeTrue("keytool needed", real != null && fake != null)
        try {
            assertEquals(ProbeResult.MATCH, PinnedProbe.check("127.0.0.1", real!!.port, real.sha256))
            // the lookalike answers on its own port with its own certificate: the pinned fingerprint is the real one's
            assertEquals(ProbeResult.PIN_MISMATCH, PinnedProbe.check("127.0.0.1", fake!!.port, real.sha256))
            assertEquals("the probe sends no application data at all, so no token", 0, real.received.get() + fake.received.get())
        } finally { real?.close(); fake?.close() }
    }

    @Test fun nothingListeningIsUnreachableNotAMismatch() {
        val s = java.net.ServerSocket(0).also { it.close() } // a port that was free a moment ago
        assertEquals(ProbeResult.UNREACHABLE, PinnedProbe.check("127.0.0.1", s.localPort, "ab".repeat(32)))
    }

    @Test fun theRealLinkNeverSendsTheTokenToAMismatchingCertificate() {
        val d = dir()
        val real = server(d, "real2"); val fake = server(d, "fake2")
        assumeTrue("keytool needed", real != null && fake != null)
        try {
            val token = "secret_token_1234567"
            // paired with the real certificate, but the address found points at the lookalike
            val pairing = PairingPayload("127.0.0.1", fake!!.port, real!!.sha256, token, "PC")
            val failed = runCatching { PinnedTls.connector(pairing).connect(2_000) }
            assertTrue("the handshake must fail", failed.isFailure)
            Thread.sleep(300)
            assertEquals("the lookalike received nothing", 0, fake.received.get())
            assertEquals("and never completed a handshake with us", 0, fake.handshakes)
        } finally { real?.close(); fake?.close() }
    }
}
