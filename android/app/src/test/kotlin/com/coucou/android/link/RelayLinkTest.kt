package com.coucou.android.link

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The relay fields of a pairing link, how they are kept, and the relay's text hints. */
class RelayLinkTest {
    private val room = RelayCrypto.base64UrlEncode(ByteArray(16) { 1 })
    private val key = RelayCrypto.base64UrlEncode(ByteArray(32) { 2 })
    private val access = RelayCrypto.base64UrlEncode(ByteArray(32) { 3 })
    private val fp = "ab".repeat(32)
    private val lan = "coucou://pair?v=1&host=192.168.1.20&port=47821&fp=$fp&token=tok_en-1234567890abcd&name=PC"
    private val withRelay = "$lan&relay=wss:%2F%2Frelay.example.workers.dev&room=$room&key=$key&access=$access"

    @Test fun anOldLinkStillPairsOverTheLanOnly() {
        val p = PairingPayload.parse(lan)!!
        assertNull(p.relay)
        assertEquals("192.168.1.20", p.host)
    }

    @Test fun aLinkWithTheRelayFieldsCarriesThemAll() {
        val p = PairingPayload.parse(withRelay)!!
        val r = p.relay!!
        assertEquals("wss://relay.example.workers.dev", r.url)
        assertEquals(room, r.room)
        assertEquals(key, r.key)
        assertEquals(access, r.access)
        assertNotNull(r.pairingKey())
        assertEquals("wss://relay.example.workers.dev", r.relayUrl()!!.display)
        assertEquals(443, r.relayUrl()!!.port)
    }

    @Test fun thePortInTheAddressIsKept() {
        val p = PairingPayload.parse(withRelay.replace("workers.dev", "workers.dev:8443"))!!
        assertEquals(8443, p.relay!!.relayUrl()!!.port)
    }

    @Test fun someOfTheFieldsButNotAllIsADamagedLink() {
        for (missing in listOf("relay", "room", "key", "access")) {
            val link = withRelay.split("&").filterNot { it.startsWith("$missing=") }.joinToString("&")
            assertNull("without $missing", PairingPayload.parse(link))
        }
    }

    @Test fun aMalformedFieldMakesTheWholeLinkInvalid() {
        val bad = mapOf(
            "room too short" to withRelay.replace(room, room.dropLast(1)),
            "room not base64url" to withRelay.replace(room, "!".repeat(22)),
            "key too short" to withRelay.replace(key, key.dropLast(1)),
            "key too long" to withRelay.replace(key, key + "A"),
            "access too short" to withRelay.replace(access, access.dropLast(2)),
            "access with padding" to withRelay.replace(access, access.dropLast(1) + "="),
            "plain http" to withRelay.replace("wss:%2F%2F", "https:%2F%2F"),
            "ws to another host" to withRelay.replace("wss:%2F%2Frelay.example.workers.dev", "ws:%2F%2Frelay.example.workers.dev"),
            "credentials in the address" to withRelay.replace("wss:%2F%2F", "wss:%2F%2Fuser:pw%40"),
            "a path in the address" to withRelay.replace("workers.dev", "workers.dev%2Fx"),
        )
        for ((name, link) in bad) assertNull(name, PairingPayload.parse(link))
    }

    @Test fun theLanPartIsUnchangedByTheRelayFields() {
        val a = PairingPayload.parse(lan)!!
        val b = PairingPayload.parse(withRelay)!!
        assertEquals(a.copy(relay = null), b.copy(relay = null))
    }

    @Test fun aPairingNeverPrintsItsRelaySecrets() {
        val p = PairingPayload.parse(withRelay)!!
        val shown = p.relay.toString() + p.relay!!.pairingKey().toString()
        for (secret in listOf(key, access, room)) assertFalse(shown.contains(secret))
        assertFalse(p.toString().contains(key) || p.toString().contains(access) || p.toString().contains(room))
    }

    @Test fun theLongestRealisticLinkIsStillAccepted() {
        val name = java.net.URLEncoder.encode("é".repeat(48), "UTF-8").replace("+", "%20")
        val host = "${"a".repeat(63)}.${"b".repeat(63)}.workers.dev"
        val link = "coucou://pair?v=1&host=2001:db8:aaaa:bbbb:cccc:dddd:eeee:ffff&port=47821&fp=$fp&token=${"t".repeat(128)}&name=$name" +
            "&relay=wss:%2F%2F$host:8443&room=$room&key=$key&access=$access"
        assertTrue("${link.length} characters", link.length < com.coucou.android.core.PairingScan.MAX_LINK)
        assertTrue(com.coucou.android.core.PairingScan.decide(link) is com.coucou.android.core.ScanDecision.Pairing)
        assertEquals(host, PairingPayload.parse(link)!!.relay!!.relayUrl()!!.host)
    }

    @Test fun theConfirmationShowsTheRelayHostBeforeAnythingIsStored() {
        val dialog = java.io.File("src/main/kotlin/com/coucou/android/ui/PairConfirm.kt").readText()
        assertTrue(dialog.contains("p.relay?.relayUrl()?.host"))
        assertTrue(dialog.contains("R.string.pair_confirm_relay"))
    }

    @Test fun theHintsAreTheTwoExactMessages() {
        assertEquals(RelayHints.Hint.ONLINE, RelayHints.parse("""{"peer":"online"}"""))
        assertEquals(RelayHints.Hint.OFFLINE, RelayHints.parse("""{"peer":"offline"}"""))
        for (other in listOf("pong", "", """{"peer":"online","x":1}""", """{"peer":"gone"}""", "ONLINE")) {
            assertEquals(RelayHints.Hint.OTHER, RelayHints.parse(other))
        }
    }

    @Test fun aRelayAccessMessageIsAcceptedOnlyWithAWellFormedKey() {
        val ok = Wire.decodeServer("""{"type":"relayAccess","access":"$access"}""")
        assertTrue(ok is ServerMsg.RelayAccess && ok.access == access)
        assertNull(Wire.decodeServer("""{"type":"relayAccess","access":"short"}"""))
        assertNull(Wire.decodeServer("""{"type":"relayAccess"}"""))
    }
}

class PairingCodecTest {
    private val room = RelayCrypto.base64UrlEncode(ByteArray(16) { 1 })
    private val key = RelayCrypto.base64UrlEncode(ByteArray(32) { 2 })
    private val access = RelayCrypto.base64UrlEncode(ByteArray(32) { 3 })
    private val lanOnly = PairingPayload("192.168.1.20", 47821, "ab".repeat(32), "tok_en-1234567890abcd", "PC")

    @Test fun aLanPairingRoundTrips() {
        val text = PairingCodec.encode(lanOnly)
        assertEquals(5, text.split("\n").size)
        assertEquals(lanOnly, PairingCodec.decode(text))
    }

    @Test fun aPairingWithARelayRoundTripsWithAllFourFields() {
        val p = lanOnly.copy(relay = RelayPairing("wss://relay.example.workers.dev", room, key, access))
        val back = PairingCodec.decode(PairingCodec.encode(p))!!
        assertEquals(p, back)
        assertEquals(key, back.relay!!.key)
        assertEquals(access, back.relay!!.access)
    }

    @Test fun aPairingSavedByAnOlderAppStillLoadsAsLanOnly() {
        val old = listOf("192.168.1.20", "47821", "ab".repeat(32), "tok_en-1234567890abcd", "PC").joinToString("\n")
        val p = PairingCodec.decode(old)!!
        assertNull(p.relay)
        assertEquals("192.168.1.20", p.host)
    }

    @Test fun anUnreadablePairingIsNotAPairing() {
        assertNull(PairingCodec.decode(""))
        assertNull(PairingCodec.decode("a\nb"))
        assertNull(PairingCodec.decode("h\nnotaport\nfp\ntoken"))
    }
}
