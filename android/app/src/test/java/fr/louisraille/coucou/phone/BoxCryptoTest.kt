package fr.louisraille.coucou.phone

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BoxCryptoTest {
    // Pinned in mail_crypto.rs `shared_vectors` — the two implementations must
    // agree byte for byte, or the phone cannot open what the PC sealed.
    private val master = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
    private val pcId = "0123456789abcdef01234567"

    @Test
    fun theBearerIsDerivedNotTheMaster() {
        val bearer = BoxCrypto.authBearer(master, pcId)!!
        assertTrue(bearer.matches(Regex("[0-9a-f]{64}")))
        assertTrue(bearer != master)
        // Same vector as mail_crypto.rs — deterministic across implementations.
        assertEquals("afa8eb7727d17661964e487e1367f4d94022f7873433965f8663765211aa8d15", bearer)
    }

    @Test
    fun aRustSealedBlobOpensHere() {
        // Produced by mail_crypto's shared_vectors test (nonce 01..0c).
        val blob = JSONObject(
            """{"enc":1,"n":"AQIDBAUGBwgJCgsM","ct":"s9NCsOUHmz_m5rSKEVucA1ZlOHm45daYIKuASYQjPZie6MWq-I_RpJbYlDca2d5xjsjEIJzcnoha3qgnkRBEAh5PF7LkGv8kKtQQLqezCw"}"""
        )
        val (p2h, _) = BoxCrypto.ciphers(master, pcId)!!
        val plain = BoxCrypto.open(p2h, blob)!!
        assertEquals("""{"type":"decision","requestId":"r1","decision":"allow","at":42}""", String(plain, Charsets.UTF_8))
    }

    @Test
    fun aBlobRoundTripsAndTheOtherDirectionCannotReadIt() {
        val (p2h, h2p) = BoxCrypto.ciphers(master, pcId)!!
        val blob = BoxCrypto.seal(p2h, """{"type":"chat","text":"hi"}""".toByteArray(Charsets.UTF_8))
        assertEquals(1, blob.getInt("enc"))
        assertArrayEquals(
            """{"type":"chat","text":"hi"}""".toByteArray(Charsets.UTF_8),
            BoxCrypto.open(p2h, blob),
        )
        // h2p is a different key: a state blob pushed back as an outbox item opens nothing.
        assertNull(BoxCrypto.open(h2p, blob))
    }

    @Test
    fun aForgedOrCutBlobNeverOpens() {
        val (p2h, _) = BoxCrypto.ciphers(master, pcId)!!
        val blob = BoxCrypto.seal(p2h, "{}".toByteArray())
        blob.put("ct", "A" + blob.getString("ct").drop(1))
        assertNull(BoxCrypto.open(p2h, blob))
        assertNull(BoxCrypto.open(p2h, JSONObject("{}")))
        assertNull(BoxCrypto.open(p2h, JSONObject("""{"enc":1,"n":"x","ct":"y"}""")))
    }

    @Test
    fun aBlobForAnotherBoxNeverOpens() {
        val (p2h, _) = BoxCrypto.ciphers(master, pcId)!!
        val (other, _) = BoxCrypto.ciphers(master, "fedcba9876543210fedcba98")!!
        assertNull(BoxCrypto.open(other, BoxCrypto.seal(p2h, "{}".toByteArray())))
    }
}
