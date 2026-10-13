package com.coucou.android.link

import java.nio.ByteBuffer
import java.security.GeneralSecurityException
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * The end-to-end encrypted channel for the relay link (docs/RELAY_LINK.md, sections 4 and 5): the Kotlin twin of
 * windows/src-tauri/src/phone_link/relay_crypto.rs. Pure: bytes in, bytes out; no sockets, no clock, no files, no logging.
 * Both twins are checked against android/relay/test-vectors.json, so what one writes the other reads.
 *
 *  - a data frame is AES-256-GCM under a key that is fresh for this connection and specific to one direction;
 *  - the nonce is `direction ‖ 000 ‖ counter` and the counter only goes up by one, so a (key, nonce) pair never repeats;
 *  - a frame is accepted only if its counter is exactly the next expected one; any fault kills the session;
 *  - secrets print as ".." and are wiped on [wipe]; nothing here writes them anywhere.
 */
object RelayCrypto {
    const val LABEL = "coucou-relay/v1"
    const val VER = 1
    const val T_INIT = 1
    const val T_ACCEPT = 2
    const val T_DATA = 3
    /** What the relay accepts in one WebSocket message. */
    const val MAX_FRAME = 66_000
    /** A protocol v1 line, as on the LAN. */
    const val MAX_LINE = 65_536
    /** The last counter a session may use (2^32 - 1); then the phone re-handshakes. */
    const val LAST_COUNTER = 0xFFFF_FFFFL
    const val NONCE_LEN = 16
    private const val HEADER = 10
    private const val TAG = 16
    private const val MAC_LEN = 32
    private const val BLOCK = 128

    enum class Dir(val byte: Int) { PHONE_TO_HOST(1), HOST_TO_PHONE(2) }

    enum class Failure {
        /** Too short, an unknown version or an unexpected frame type. */
        BAD_HEADER,
        /** The authentication tag (or a handshake MAC) did not verify: wrong key, room or direction, altered or truncated. */
        BAD_TAG,
        /** Not the next expected counter (repeat, gap, jump) or past the last allowed. */
        BAD_COUNTER,
        BAD_PADDING,
        TOO_LONG,
        /** The session used its last counter; start a new handshake. */
        EXHAUSTED,
        /** An earlier fault ended this session. */
        FAULTED,
    }

    /** Carries only the reason: never a key, a frame or a line. */
    class ChannelException(val failure: Failure) : Exception(failure.name)

    // ── secrets ─────────────────────────────────────────────────────────────────

    /** Secret bytes: printed as "..", wiped on request. */
    class Secret(internal val bytes: ByteArray) {
        fun wipe() = bytes.fill(0)
        override fun toString() = "Secret(..)"
    }

    /** K, the pairing key from the pairing link (43 base64url characters), or made fresh. */
    class PairingKey(bytes: ByteArray) {
        private val secret = Secret(bytes.copyOf().also { require(it.size == 32) { "a pairing key has 32 bytes" } })
        internal val raw: ByteArray get() = secret.bytes
        fun toBase64Url(): String = base64UrlEncode(secret.bytes)
        fun wipe() = secret.wipe()
        override fun toString() = "PairingKey(..)"

        companion object {
            fun fromBase64Url(text: String): PairingKey? = base64UrlDecode(text)?.takeIf { it.size == 32 }?.let { PairingKey(it) }
        }
    }

    // ── derivation ──────────────────────────────────────────────────────────────

    private fun hmac(key: ByteArray, vararg parts: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(if (key.isEmpty()) ByteArray(32) else key, "HmacSHA256")) // an empty key is a zero block (RFC 2104)
        for (p in parts) mac.update(p)
        return mac.doFinal()
    }

    /** HKDF-SHA-256 (RFC 5869). */
    fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        require(length in 1..255 * 32)
        val prk = hmac(if (salt.isEmpty()) ByteArray(32) else salt, ikm)
        val out = ByteArray(length)
        var previous = ByteArray(0)
        var done = 0
        var counter = 1
        while (done < length) {
            previous = hmac(prk, previous, info, byteArrayOf(counter.toByte()))
            val n = minOf(previous.size, length - done)
            System.arraycopy(previous, 0, out, done, n)
            done += n
            counter++
        }
        return out
    }

    private fun derive32(k: PairingKey, what: String): ByteArray = hkdf(k.raw, ByteArray(0), "$LABEL $what".toByteArray(), 32)

    /** `K_auth`: MACs the two handshake frames. */
    fun kAuth(k: PairingKey): Secret = Secret(derive32(k, "auth"))

    /** `K_join`: presented to the relay as a join proof; one-way from K. */
    fun kJoin(k: PairingKey): Secret = Secret(derive32(k, "join"))

    /** The join proof for the `coucou.join.<…>` sub-protocol. */
    fun joinProof(k: PairingKey): String = base64UrlEncode(kJoin(k).bytes)

    /** The two session keys, `(phone → host, host → phone)`. */
    internal fun sessionKeys(k: PairingKey, nPhone: ByteArray, nHost: ByteArray): Pair<Secret, Secret> {
        require(nPhone.size == NONCE_LEN && nHost.size == NONCE_LEN)
        val out = hkdf(k.raw, nPhone + nHost, "$LABEL session".toByteArray(), 64)
        return Secret(out.copyOfRange(0, 32)) to Secret(out.copyOfRange(32, 64)).also { out.fill(0) }
    }

    /** `direction ‖ 0x00 0x00 0x00 ‖ counter` (12 bytes). */
    fun nonceFor(dir: Dir, counter: Long): ByteArray =
        ByteBuffer.allocate(12).put(dir.byte.toByte()).put(0).put(0).put(0).putLong(counter).array()

    private fun header(type: Int, counter: Long): ByteArray =
        ByteBuffer.allocate(HEADER).put(VER.toByte()).put(type.toByte()).putLong(counter).array()

    private fun aad(room: String, dir: Dir, header: ByteArray): ByteArray =
        LABEL.toByteArray() + room.toByteArray() + byteArrayOf(dir.byte.toByte()) + header

    // ── handshake ───────────────────────────────────────────────────────────────

    /** A fresh 16-byte handshake nonce. */
    fun freshNonce(): ByteArray = ByteArray(NONCE_LEN).also { java.security.SecureRandom().nextBytes(it) }

    private fun parseHandshake(frame: ByteArray, wanted: Int): Pair<ByteArray, ByteArray> {
        val zeroCounter = frame.size >= HEADER && (2 until HEADER).all { frame[it] == 0.toByte() }
        if (frame.size != HEADER + NONCE_LEN + MAC_LEN || frame[0].toInt() != VER || frame[1].toInt() != wanted || !zeroCounter) {
            throw ChannelException(Failure.BAD_HEADER)
        }
        return frame.copyOfRange(HEADER, HEADER + NONCE_LEN) to frame.copyOfRange(HEADER + NONCE_LEN, frame.size)
    }

    private fun macOk(auth: Secret, tag: ByteArray, vararg parts: ByteArray) = MessageDigest.isEqual(hmac(auth.bytes, *parts), tag) // constant time

    /** The phone's first frame; it must remember [nPhone] to check the answer. */
    fun initFrame(k: PairingKey, room: String, nPhone: ByteArray): ByteArray {
        require(nPhone.size == NONCE_LEN)
        val tag = hmac(kAuth(k).bytes, "init".toByteArray(), room.toByteArray(), nPhone)
        return header(T_INIT, 0) + nPhone + tag
    }

    /** The computer's side (used by tests and tools): checks an `init`, answers `accept`, and returns the session. */
    fun acceptInit(k: PairingKey, room: String, init: ByteArray, nHost: ByteArray): Pair<ByteArray, Session> {
        require(nHost.size == NONCE_LEN)
        val (nPhone, tag) = parseHandshake(init, T_INIT)
        val auth = kAuth(k)
        if (!macOk(auth, tag, "init".toByteArray(), room.toByteArray(), nPhone)) throw ChannelException(Failure.BAD_TAG)
        val reply = hmac(auth.bytes, "accept".toByteArray(), room.toByteArray(), nPhone, nHost)
        val (p2h, h2p) = sessionKeys(k, nPhone, nHost)
        return (header(T_ACCEPT, 0) + nHost + reply) to Session(Dir.HOST_TO_PHONE, room, p2h, h2p)
    }

    /** The phone's side: checks that the `accept` answers **its current** nonce, and returns the session. */
    fun finishHandshake(k: PairingKey, room: String, nPhone: ByteArray, accept: ByteArray): Session {
        val (nHost, tag) = parseHandshake(accept, T_ACCEPT)
        if (!macOk(kAuth(k), tag, "accept".toByteArray(), room.toByteArray(), nPhone, nHost)) throw ChannelException(Failure.BAD_TAG)
        val (p2h, h2p) = sessionKeys(k, nPhone, nHost)
        return Session(Dir.PHONE_TO_HOST, room, p2h, h2p)
    }

    // ── the session ─────────────────────────────────────────────────────────────

    /** One connection's keys and counters. Not thread safe: one reader and one writer thread should each use their own call path under a lock. */
    class Session internal constructor(private val me: Dir, private val room: String, p2h: Secret, h2p: Secret) {
        internal val sendKey: Secret = if (me == Dir.PHONE_TO_HOST) p2h else h2p
        internal val recvKey: Secret = if (me == Dir.PHONE_TO_HOST) h2p else p2h
        private var sendCounter = 0L
        private var recvNext = 0L
        private var sendDone = false
        private var faulted = false

        /** The next counter this side will send (carries no secret). */

        /** Encrypts one protocol v1 line (UTF-8 JSON, without the newline) into a binary frame. */
        @Synchronized fun seal(line: ByteArray): ByteArray {
            if (faulted) throw ChannelException(Failure.FAULTED)
            if (line.size > MAX_LINE) throw ChannelException(Failure.TOO_LONG)
            if (sendDone) throw ChannelException(Failure.EXHAUSTED)
            val counter = sendCounter
            val frame = sealWith(sendKey.bytes, room, me, counter, line)
            if (counter == LAST_COUNTER) sendDone = true else sendCounter++
            return frame
        }

        /** Decrypts a binary frame from the other side. The counter must be exactly the next one. Any error ends the session. */
        @Synchronized fun open(frame: ByteArray): ByteArray {
            if (faulted) throw ChannelException(Failure.FAULTED)
            try {
                if (frame.size > MAX_FRAME) throw ChannelException(Failure.TOO_LONG)
                if (frame.size < HEADER + TAG || frame[0].toInt() != VER || frame[1].toInt() != T_DATA) throw ChannelException(Failure.BAD_HEADER)
                val counter = ByteBuffer.wrap(frame, 2, 8).long
                if (counter != recvNext || counter < 0 || counter > LAST_COUNTER) throw ChannelException(Failure.BAD_COUNTER)
                val line = openWith(recvKey.bytes, room, if (me == Dir.PHONE_TO_HOST) Dir.HOST_TO_PHONE else Dir.PHONE_TO_HOST, frame)
                recvNext = counter + 1
                return line
            } catch (e: ChannelException) {
                faulted = true
                throw e
            }
        }

        /** Tests only: makes the next frame carry this counter (to reach the last counter without sending 2^32 frames). */
        @Synchronized internal fun forceSendCounterForTest(counter: Long) {
            sendCounter = counter
        }

        /** Wipes the keys; the session is unusable afterwards. */
        @Synchronized fun wipe() {
            sendKey.wipe()
            recvKey.wipe()
            faulted = true
        }

        override fun toString() = "Session(..)"
    }

    /** 4-byte length, the line, then zeros up to a multiple of 128 bytes (at least 128). */
    internal fun pad(line: ByteArray): ByteArray {
        val raw = 4 + line.size
        val total = maxOf(1, (raw + BLOCK - 1) / BLOCK) * BLOCK
        return ByteBuffer.allocate(total).putInt(line.size).put(line).array()
    }

    private fun unpad(plain: ByteArray): ByteArray {
        if (plain.size < BLOCK || plain.size % BLOCK != 0) throw ChannelException(Failure.BAD_PADDING)
        val n = ByteBuffer.wrap(plain, 0, 4).int
        if (n < 0 || n > MAX_LINE || 4 + n > plain.size || (4 + n until plain.size).any { plain[it] != 0.toByte() }) throw ChannelException(Failure.BAD_PADDING)
        return plain.copyOfRange(4, 4 + n)
    }

    private fun cipher(mode: Int, key: ByteArray, nonce: ByteArray, aad: ByteArray): Cipher =
        Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(mode, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
            updateAAD(aad)
        }

    /** Encrypts at an explicit counter. The session guarantees it is never reused; tests use it for the vectors. */
    internal fun sealWith(key: ByteArray, room: String, dir: Dir, counter: Long, line: ByteArray): ByteArray {
        val h = header(T_DATA, counter)
        val body = cipher(Cipher.ENCRYPT_MODE, key, nonceFor(dir, counter), aad(room, dir, h)).doFinal(pad(line))
        return h + body
    }

    /** The header is already checked by the caller; verifies the tag under the direction's key and unpads. */
    internal fun openWith(key: ByteArray, room: String, dir: Dir, frame: ByteArray): ByteArray {
        val h = frame.copyOfRange(0, HEADER)
        val counter = ByteBuffer.wrap(h, 2, 8).long
        val plain = try {
            cipher(Cipher.DECRYPT_MODE, key, nonceFor(dir, counter), aad(room, dir, h)).doFinal(frame, HEADER, frame.size - HEADER)
        } catch (e: GeneralSecurityException) {
            throw ChannelException(Failure.BAD_TAG)
        }
        try {
            return unpad(plain)
        } finally {
            plain.fill(0)
        }
    }

    // ── base64url (no padding), strict ──────────────────────────────────────────

    private const val B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

    fun base64UrlEncode(bytes: ByteArray): String {
        val sb = StringBuilder()
        var i = 0
        while (i < bytes.size) {
            val b0 = bytes[i].toInt() and 0xff
            val b1 = if (i + 1 < bytes.size) bytes[i + 1].toInt() and 0xff else 0
            val b2 = if (i + 2 < bytes.size) bytes[i + 2].toInt() and 0xff else 0
            val n = (b0 shl 16) or (b1 shl 8) or b2
            sb.append(B64[(n shr 18) and 63]).append(B64[(n shr 12) and 63])
            if (i + 1 < bytes.size) sb.append(B64[(n shr 6) and 63])
            if (i + 2 < bytes.size) sb.append(B64[n and 63])
            i += 3
        }
        return sb.toString()
    }

    /** Only the 64 URL-safe characters, no padding, and the unused trailing bits must be zero. */
    fun base64UrlDecode(text: String): ByteArray? {
        if (text.length % 4 == 1) return null
        val out = java.io.ByteArrayOutputStream()
        var i = 0
        while (i < text.length) {
            val chunk = text.substring(i, minOf(i + 4, text.length))
            var n = 0
            for ((j, c) in chunk.withIndex()) {
                val v = B64.indexOf(c)
                if (v < 0) return null
                n = n or (v shl (18 - 6 * j))
            }
            val take = chunk.length * 6 / 8
            val unusedBits = chunk.length * 6 - take * 8
            if (unusedBits > 0 && ((n shr (24 - chunk.length * 6)) and ((1 shl unusedBits) - 1)) != 0) return null
            for (k in 0 until take) out.write((n shr (16 - 8 * k)) and 0xff)
            i += 4
        }
        return out.toByteArray()
    }
}
