package com.coucou.android.link

import com.coucou.android.link.RelayCrypto.ChannelException
import com.coucou.android.link.RelayCrypto.Dir
import com.coucou.android.link.RelayCrypto.Failure
import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The same checks as the Rust twin, against the same android/relay/test-vectors.json. */
class RelayCryptoTest {
    private val v = JSONObject(File("../relay/test-vectors.json").readText())
    private fun hex(s: String) = ByteArray(s.length / 2) { s.substring(2 * it, 2 * it + 2).toInt(16).toByte() }
    private fun ByteArray.hex() = joinToString("") { "%02x".format(it) }
    private fun text(vararg path: String): String {
        var o = v
        for (p in path.dropLast(1)) o = o.getJSONObject(p)
        return o.getString(path.last())
    }
    private val k = RelayCrypto.PairingKey(hex(text("inputs", "key")))
    private val room = text("inputs", "room")
    private val nPhone = hex(text("inputs", "nPhone"))
    private val nPc = hex(text("inputs", "nPc"))
    private fun dir(s: String) = if (s == "p2h") Dir.PHONE_TO_HOST else Dir.HOST_TO_PHONE
    private fun failure(block: () -> Unit): Failure? = try { block(); null } catch (e: ChannelException) { e.failure }

    /** The session that RECEIVES frames sent in direction [d], built from the vectors' handshake. */
    private fun receiverOf(d: Dir, key: RelayCrypto.PairingKey = k, roomText: String = room): RelayCrypto.Session {
        val init = RelayCrypto.initFrame(key, roomText, nPhone)
        val (accept, host) = RelayCrypto.acceptInit(key, roomText, init, nPc)
        return if (d == Dir.PHONE_TO_HOST) host else RelayCrypto.finishHandshake(key, roomText, nPhone, accept)
    }

    @Test fun hkdfMatchesRfc5869A1() {
        val r = v.getJSONObject("rfc5869_a1")
        assertEquals(r.getString("okm"), RelayCrypto.hkdf(hex(r.getString("ikm")), hex(r.getString("salt")), hex(r.getString("info")), r.getInt("length")).hex())
    }

    @Test fun derivedKeysMatchTheVectors() {
        assertEquals(text("derived", "kAuth"), RelayCrypto.kAuth(k).bytes.hex())
        assertEquals(text("derived", "kJoin"), RelayCrypto.kJoin(k).bytes.hex())
        val (p2h, h2p) = RelayCrypto.sessionKeys(k, nPhone, nPc)
        assertEquals(text("derived", "kP2H"), p2h.bytes.hex())
        assertEquals(text("derived", "kH2P"), h2p.bytes.hex())
        assertEquals(43, RelayCrypto.joinProof(k).length)
        assertEquals(RelayCrypto.base64UrlEncode(RelayCrypto.kJoin(k).bytes), RelayCrypto.joinProof(k))
    }

    @Test fun theHandshakeFramesMatchTheVectorsAndTheTwoSidesAgree() {
        val init = RelayCrypto.initFrame(k, room, nPhone)
        assertEquals(text("init", "frame"), init.hex())
        val (accept, host) = RelayCrypto.acceptInit(k, room, init, nPc)
        assertEquals(text("accept", "frame"), accept.hex())
        val phone = RelayCrypto.finishHandshake(k, room, nPhone, accept)
        val a = phone.seal("""{"type":"hello"}""".toByteArray())
        assertArrayEquals("""{"type":"hello"}""".toByteArray(), host.open(a))
        val b = host.seal("""{"type":"welcome"}""".toByteArray())
        assertArrayEquals("""{"type":"welcome"}""".toByteArray(), phone.open(b))
    }

    @Test fun aWrongKeyRoomOrStaleAcceptIsRefused() {
        val init = RelayCrypto.initFrame(k, room, nPhone)
        val other = RelayCrypto.PairingKey(ByteArray(32) { 9 })
        assertEquals(Failure.BAD_TAG, failure { RelayCrypto.acceptInit(other, room, init, nPc) })
        assertEquals(Failure.BAD_TAG, failure { RelayCrypto.acceptInit(k, "AAAAAAAAAAAAAAAAAAAAAA", init, nPc) })
        val (accept, _) = RelayCrypto.acceptInit(k, room, init, nPc)
        assertEquals("a recorded accept must not answer a newer init", Failure.BAD_TAG, failure { RelayCrypto.finishHandshake(k, room, ByteArray(16) { 7 }, accept) })
        assertEquals(Failure.BAD_HEADER, failure { RelayCrypto.finishHandshake(k, room, nPhone, init) })
        assertEquals(Failure.BAD_HEADER, failure { RelayCrypto.acceptInit(k, room, accept, nPc) })
        assertEquals(Failure.BAD_HEADER, failure { RelayCrypto.acceptInit(k, room, init.copyOf(40), nPc) })
        val flipped = init.copyOf().also { it[12] = (it[12].toInt() xor 1).toByte() }
        assertEquals(Failure.BAD_TAG, failure { RelayCrypto.acceptInit(k, room, flipped, nPc) })
    }

    @Test fun dataFramesReproduceTheVectorsByteForByteAndOpenBack() {
        val (p2h, h2p) = RelayCrypto.sessionKeys(k, nPhone, nPc)
        val cases = v.getJSONArray("data")
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val d = dir(c.getString("dir"))
            val key = if (d == Dir.PHONE_TO_HOST) p2h else h2p
            val counter = c.getLong("counter")
            val line = c.getString("line").toByteArray()
            assertEquals(c.getString("nonce"), RelayCrypto.nonceFor(d, counter).hex())
            assertEquals(c.getString("plaintext"), RelayCrypto.pad(line).hex())
            val sealed = RelayCrypto.sealWith(key.bytes, room, d, counter, line)
            assertEquals("$d $counter", c.getString("frame"), sealed.hex())
            assertArrayEquals(line, RelayCrypto.openWith(key.bytes, room, d, sealed))
        }
    }

    @Test fun framesThatMustBeRefusedAreRefusedWithTheListedReason() {
        val list = v.getJSONArray("mustRefuse")
        for (i in 0 until list.length()) {
            val n = list.getJSONObject(i)
            val d = dir(n.getString("dir"))
            val key = if (n.has("key")) RelayCrypto.PairingKey(hex(n.getString("key"))) else k
            val rx = receiverOf(d, key, if (n.has("room")) n.getString("room") else room)
            val name = n.getString("name")
            val expected = if (name == "the counter in the header changed") Failure.BAD_COUNTER // refused by the counter rule first
            else if (n.getString("expect") == "bad_tag") Failure.BAD_TAG else Failure.BAD_HEADER
            val frame = hex(n.getString("frame"))
            assertEquals(name, expected, failure { rx.open(frame) })
            assertEquals("$name: the session is dead after a fault", Failure.FAULTED, failure { rx.open(frame) })
        }
    }

    @Test fun counterSequencesFollowTheRule() {
        val (p2h, _) = RelayCrypto.sessionKeys(k, nPhone, nPc)
        val list = v.getJSONArray("mustRefuseInOrder")
        for (i in 0 until list.length()) {
            val s = list.getJSONObject(i)
            val rx = receiverOf(Dir.PHONE_TO_HOST)
            val counters = s.getJSONArray("counters")
            val want = s.getJSONArray("accepted")
            val got = (0 until counters.length()).map {
                val frame = RelayCrypto.sealWith(p2h.bytes, room, Dir.PHONE_TO_HOST, counters.getLong(it), """{"type":"ping"}""".toByteArray())
                failure { rx.open(frame) } == null
            }
            assertEquals(s.getString("name"), (0 until want.length()).map { want.getBoolean(it) }, got)
        }
    }

    @Test fun noKeyAndNoncePairRepeatsAcrossBothDirectionsAndTwoSessions() {
        val seen = HashSet<String>()
        val key = RelayCrypto.PairingKey(ByteArray(32) { 3 })
        for ((np, nh) in listOf(ByteArray(16) { 1 } to ByteArray(16) { 2 }, ByteArray(16) { 5 } to ByteArray(16) { 6 })) {
            val (p2h, h2p) = RelayCrypto.sessionKeys(key, np, nh)
            assertFalse("the directions share a key", p2h.bytes.contentEquals(h2p.bytes))
            for (c in 0L until 3000L) {
                assertTrue("p2h $c", seen.add(p2h.bytes.hex() + ":" + RelayCrypto.nonceFor(Dir.PHONE_TO_HOST, c).hex()))
                assertTrue("h2p $c", seen.add(h2p.bytes.hex() + ":" + RelayCrypto.nonceFor(Dir.HOST_TO_PHONE, c).hex()))
            }
        }
        assertEquals(2 * 2 * 3000, seen.size)
        assertFalse(RelayCrypto.nonceFor(Dir.PHONE_TO_HOST, 5).contentEquals(RelayCrypto.nonceFor(Dir.HOST_TO_PHONE, 5)))
    }

    @Test fun theSessionsThemselvesReproduceTheVectorFramesInEachDirection() {
        val phone = receiverOf(Dir.HOST_TO_PHONE)
        val host = receiverOf(Dir.PHONE_TO_HOST)
        var checked = 0
        val cases = v.getJSONArray("data")
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val d = dir(c.getString("dir"))
            if (c.getLong("counter") > 2) continue
            val (sender, receiver) = if (d == Dir.PHONE_TO_HOST) phone to host else host to phone
            val frame = sender.seal(c.getString("line").toByteArray())
            assertEquals(c.getString("frame"), frame.hex())
            assertArrayEquals(c.getString("line").toByteArray(), receiver.open(frame))
            checked++
        }
        assertEquals(5, checked)
        assertFalse("a session must not send and receive under one key", phone.sendKey.bytes.contentEquals(phone.recvKey.bytes))
        assertFalse(host.sendKey.bytes.contentEquals(host.recvKey.bytes))
        assertArrayEquals(phone.sendKey.bytes, host.recvKey.bytes)
        assertArrayEquals(host.sendKey.bytes, phone.recvKey.bytes)
    }

    @Test fun aSessionSendsCountersInOrderAndNeverReusesOne() {
        val host = receiverOf(Dir.PHONE_TO_HOST)
        val counters = (0 until 500).map { java.nio.ByteBuffer.wrap(host.seal("{}".toByteArray()), 2, 8).long }
        assertEquals((0L until 500L).toList(), counters)
    }

    @Test fun aSenderAtTheLastCounterSendsItOnceAndThenRefuses() {
        val host = receiverOf(Dir.PHONE_TO_HOST)
        host.forceSendCounterForTest(RelayCrypto.LAST_COUNTER - 1)
        host.seal("{}".toByteArray())
        val last = host.seal("{}".toByteArray())
        assertEquals(RelayCrypto.LAST_COUNTER, java.nio.ByteBuffer.wrap(last, 2, 8).long)
        assertEquals(Failure.EXHAUSTED, failure { host.seal("{}".toByteArray()) })
        assertEquals(Failure.EXHAUSTED, failure { host.seal("{}".toByteArray()) })
    }

    @Test fun aReceiverRefusesACounterPastTheLastOne() {
        val (p2h, _) = RelayCrypto.sessionKeys(k, nPhone, nPc)
        val rx = receiverOf(Dir.PHONE_TO_HOST)
        val beyond = RelayCrypto.sealWith(p2h.bytes, room, Dir.PHONE_TO_HOST, RelayCrypto.LAST_COUNTER + 1, "{}".toByteArray())
        assertEquals(Failure.BAD_COUNTER, failure { rx.open(beyond) })
    }

    @Test fun linesPadToBlocksAndTheSizeLimitHolds() {
        assertEquals(128, RelayCrypto.pad(ByteArray(0)).size)
        assertEquals(128, RelayCrypto.pad(ByteArray(124)).size)
        assertEquals(256, RelayCrypto.pad(ByteArray(125)).size)
        val tx = receiverOf(Dir.PHONE_TO_HOST)
        val rx = receiverOf(Dir.HOST_TO_PHONE)
        val biggest = ByteArray(RelayCrypto.MAX_LINE) { 'x'.code.toByte() }
        val frame = tx.seal(biggest)
        assertTrue("${frame.size} bytes", frame.size <= RelayCrypto.MAX_FRAME)
        assertArrayEquals(biggest, rx.open(frame))
        assertEquals(Failure.TOO_LONG, failure { tx.seal(ByteArray(RelayCrypto.MAX_LINE + 1)) })
        assertEquals(Failure.TOO_LONG, failure { rx.open(ByteArray(RelayCrypto.MAX_FRAME + 1)) })
    }

    @Test fun aFrameWithBadPaddingIsRefusedEvenWithAValidTag() {
        val (p2h, _) = RelayCrypto.sessionKeys(k, nPhone, nPc)
        val shapes = listOf(
            ByteArray(100),
            RelayCrypto.pad("{}".toByteArray()).also { it[100] = 1 },
            RelayCrypto.pad("{}".toByteArray()).also { java.nio.ByteBuffer.wrap(it).putInt(200) },
        )
        for (plain in shapes) {
            val h = java.nio.ByteBuffer.allocate(10).put(1).put(3).putLong(0).array()
            val aad = (RelayCrypto.LABEL.toByteArray() + room.toByteArray() + byteArrayOf(1) + h)
            val c = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
            c.init(javax.crypto.Cipher.ENCRYPT_MODE, javax.crypto.spec.SecretKeySpec(p2h.bytes, "AES"), javax.crypto.spec.GCMParameterSpec(128, RelayCrypto.nonceFor(Dir.PHONE_TO_HOST, 0)))
            c.updateAAD(aad)
            val frame = h + c.doFinal(plain)
            assertEquals(Failure.BAD_PADDING, failure { receiverOf(Dir.PHONE_TO_HOST).open(frame) })
        }
    }

    @Test fun base64UrlRoundTripsAndIsStrict() {
        for (len in 0 until 40) {
            val bytes = ByteArray(len) { (it * 37).toByte() }
            assertArrayEquals("$len", bytes, RelayCrypto.base64UrlDecode(RelayCrypto.base64UrlEncode(bytes)))
        }
        assertEquals(text("inputs", "room"), RelayCrypto.base64UrlEncode(hex(text("inputs", "roomBytes"))))
        assertEquals("-_8", RelayCrypto.base64UrlEncode(byteArrayOf(0xfb.toByte(), 0xff.toByte())))
        for (bad in listOf("A", "AAAAA", "AA=A", "A+AA", "A/AA", "AB", "AAB", "a b ")) assertNull(bad, RelayCrypto.base64UrlDecode(bad))
        assertNotNull(RelayCrypto.PairingKey.fromBase64Url(RelayCrypto.base64UrlEncode(ByteArray(32) { 1 })))
        assertNull(RelayCrypto.PairingKey.fromBase64Url(RelayCrypto.base64UrlEncode(ByteArray(31) { 1 })))
    }

    @Test fun secretsNeverPrintAndTheModuleNeverLogs() {
        val key = RelayCrypto.PairingKey(ByteArray(32) { 0xab.toByte() })
        val shown = "$key ${RelayCrypto.kAuth(key)} ${receiverOf(Dir.PHONE_TO_HOST)}"
        assertFalse(shown, shown.contains("ab") || shown.contains("171"))
        assertEquals("Session(..)", receiverOf(Dir.PHONE_TO_HOST).toString())
        val src = File("src/main/kotlin/com/coucou/android/link/RelayCrypto.kt").readText()
        for (bad in listOf("Log.", "println", "System.out", "System.err", "printStackTrace", "File(", "FileOutputStream", "SharedPreferences", "Timber")) {
            assertFalse("RelayCrypto.kt uses $bad", src.contains(bad))
        }
        assertNotEquals("", src)
    }

    @Test fun wipingASessionKillsIt() {
        val s = receiverOf(Dir.PHONE_TO_HOST)
        val key = s.sendKey.bytes
        s.wipe()
        assertTrue(key.all { it == 0.toByte() })
        assertEquals(Failure.FAULTED, failure { s.seal("{}".toByteArray()) })
    }
}
