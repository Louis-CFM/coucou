package com.coucou.android.link

import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * The phone's half of the end-to-end check. The computer's half is the Rust test `e2e_the_computer_side_for_the_phone_test`,
 * and between them is a real relay (the Cloudflare Worker under `wrangler dev`, or the Node twin). Both halves use the same
 * fixed credentials. Run by android/relay/tools/e2e.sh; skipped everywhere else (it needs COUCOU_E2E_RELAY_URL).
 */
class RelayE2ETest {
    private val url = System.getenv("COUCOU_E2E_RELAY_URL")
    private val room = RelayCrypto.base64UrlEncode(ByteArray(16) { 0x11 })
    private val key = RelayCrypto.base64UrlEncode(ByteArray(32) { 0x22 })
    private val access = RelayCrypto.base64UrlEncode(ByteArray(32) { 0x33 })

    private fun pairing(accessKey: String = access) = RelayPairing(url, room, key, accessKey)

    @Test fun aWrongAccessKeyIsRefusedByTheRealRelay() {
        assumeTrue("needs COUCOU_E2E_RELAY_URL", url != null)
        val c = RelayConnector(pairing(RelayCrypto.base64UrlEncode(ByteArray(32) { 0x44 })))
        try { c.connect(5_000); fail() } catch (e: WsHandshakeException) { assertEquals(401, e.status) }
        assertEquals(RelayIssue.ACCESS_REFUSED, c.issue)
    }

    @Test fun theRustComputerAndTheKotlinPhoneTalkThroughTheRealRelayAndAnApprovalIsDecided() {
        assumeTrue("needs COUCOU_E2E_RELAY_URL", url != null)
        val welcomed = CountDownLatch(1)
        val approvals = LinkedBlockingQueue<ApprovalRequest>()
        val resolved = LinkedBlockingQueue<String>()
        val listener = object : LinkListener {
            override fun onWelcome(desktopName: String, os: String) { assertEquals("E2E PC", desktopName); welcomed.countDown() }
            override fun onApproval(request: ApprovalRequest) { approvals.put(request) }
            override fun onApprovalResolved(fingerprint: String) { resolved.put(fingerprint) }
        }
        val payload = PairingPayload("192.0.2.1", 1, "ab".repeat(32), "e2e-token-0123456789abcdef", "E2E PC", pairing())
        // The computer may start a little after the phone: the connector waits for it and the link retries.
        val client = LinkClient(
            payload, "Phone", listener, connector = RelayConnector(pairing(), answerTimeoutMs = 20_000),
            backoffMs = longArrayOf(500, 1_000, 2_000), caps = Protocol.CAPABILITIES,
        )
        client.start()
        try {
            assertTrue("the computer's welcome arrived through the relay", welcomed.await(60, TimeUnit.SECONDS))
            val request = approvals.poll(30, TimeUnit.SECONDS) ?: throw IOException("no approval")
            assertEquals("Bash", request.tool)
            assertEquals("echo end-to-end", request.command)
            assertEquals(64, request.fingerprint.length)
            assertTrue(client.decide(request.fingerprint, true))
            assertEquals("the computer closed the approval after the decision", request.fingerprint, resolved.poll(30, TimeUnit.SECONDS))
        } finally {
            client.stop()
        }
    }
}
