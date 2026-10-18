package fr.louisraille.coucou.phone

import org.json.JSONObject
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * End-to-end encryption for the relay mailbox — the Kotlin twin of
 * windows/src-tauri/src/mail_crypto.rs, same derivations byte for byte.
 *
 * The pairing code's `secret` field is a master the relay never sees: calls
 * authenticate with HKDF(master, "auth") while state and outbox items travel
 * as {"enc":1,"n":…,"ct":…} AES-256-GCM blobs. A relay that logs every request
 * learns the bearer but cannot derive the keys — it can hold our blobs, never
 * read or forge them.
 *
 *   master ── "auth" ──> bearer sent as `secret`
 *   master ── "p2h" ───> AES key for phone → PC outbox items
 *   master ── "h2p" ───> AES key for PC → phone state
 *
 * The AAD names the label, the box id and the direction: a blob verifies in
 * no other box and no other direction.
 */
object BoxCrypto {
    private const val LABEL = "coucou-mailbox/v1"
    private const val NONCE = 12
    // URL-safe, no padding — same alphabet as relay_crypto.rs writes.
    private val b64 = Base64.getUrlEncoder().withoutPadding()
    private val b64dec = Base64.getUrlDecoder()
    private val random = SecureRandom()

    private fun unhex(s: String): ByteArray? {
        if (s.length % 2 != 0 || s.any { !it.isDigit() && it.lowercaseChar() !in 'a'..'f' }) return null
        return ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    }

    private fun hmac(key: ByteArray, data: ByteArray): ByteArray =
        Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(key, "HmacSHA256")) }.doFinal(data)

    /** HKDF-SHA-256 (RFC 5869): extract with the salt, expand into `len` bytes. */
    private fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, len: Int): ByteArray {
        val prk = hmac(if (salt.isEmpty()) ByteArray(32) else salt, ikm)
        var t = ByteArray(0)
        var okm = ByteArray(0)
        var i = 0
        while (okm.size < len) {
            i++
            t = hmac(prk, t + info + byteArrayOf(i.toByte()))
            okm += t
        }
        return okm.copyOf(len)
    }

    private fun derive(master: ByteArray, pcId: ByteArray, what: String): ByteArray =
        hkdf(master, pcId, "$LABEL $what".toByteArray(Charsets.UTF_8), 32)

    /** The bearer sent to the relay as `secret` — never the master itself. */
    fun authBearer(masterHex: String, pcIdHex: String): String? {
        val m = unhex(masterHex) ?: return null
        val id = unhex(pcIdHex) ?: return null
        return derive(m, id, "auth").joinToString("") { "%02x".format(it) }
    }

    /** One direction's AES key and the AAD every blob is checked under. */
    class CipherCtx(val key: ByteArray, val aad: ByteArray)

    /** Both directions for a box: `(phone → PC, PC → phone)`. Null on bad hex. */
    fun ciphers(masterHex: String, pcIdHex: String): Pair<CipherCtx, CipherCtx>? {
        val m = unhex(masterHex) ?: return null
        val id = unhex(pcIdHex) ?: return null
        fun aad(dir: String) = "$LABEL $pcIdHex $dir".toByteArray(Charsets.UTF_8)
        return CipherCtx(derive(m, id, "p2h"), aad("p2h")) to CipherCtx(derive(m, id, "h2p"), aad("h2p"))
    }

    /** `plain` → {"enc":1,"n":…,"ct":…} with a fresh nonce. */
    fun seal(ctx: CipherCtx, plain: ByteArray): JSONObject {
        val nonce = ByteArray(NONCE).also { random.nextBytes(it) }
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(ctx.key, "AES"), GCMParameterSpec(128, nonce))
        c.updateAAD(ctx.aad)
        return JSONObject()
            .put("enc", 1)
            .put("n", b64.encodeToString(nonce))
            .put("ct", b64.encodeToString(c.doFinal(plain)))
    }

    /** A stored blob back to its bytes, or null for anything that is not a blob
     * or fails its tag — wrong key, forged, cut, or replayed across boxes. */
    fun open(ctx: CipherCtx, blob: JSONObject): ByteArray? {
        if (blob.optInt("enc") != 1) return null
        val n = runCatching { b64dec.decode(blob.optString("n")) }.getOrNull() ?: return null
        val body = runCatching { b64dec.decode(blob.optString("ct")) }.getOrNull() ?: return null
        if (n.size != NONCE || body.isEmpty()) return null
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, SecretKeySpec(ctx.key, "AES"), GCMParameterSpec(128, n))
        c.updateAAD(ctx.aad)
        return runCatching { c.doFinal(body) }.getOrNull()
    }
}
