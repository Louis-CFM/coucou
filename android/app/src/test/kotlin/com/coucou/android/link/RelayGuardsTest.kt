package com.coucou.android.link

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Rules about the relay code that no behaviour test would notice breaking. */
class RelayGuardsTest {
    private fun main(path: String) = File("src/main/kotlin/com/coucou/android/$path").readText()

    @Test fun theWebSocketRelayAndTransportCodeNeverLogOrPrint() {
        for (f in listOf("link/WebSocket.kt", "link/RelayLink.kt", "link/Transport.kt", "link/RelayCrypto.kt")) {
            val text = main(f)
            for (bad in listOf("Log.", "println", "printStackTrace", "System.err", "System.out")) assertFalse("$f uses $bad", text.contains(bad))
        }
    }

    @Test fun noLogLineInTheAppNamesARelaySecret() {
        val model = main("app/AppModel.kt")
        for (line in model.lines().filter { it.contains("Log.") }) {
            for (secret in listOf(".access", ".key", ".room", "pairingKey", "relay.url")) assertFalse("a log line names $secret: $line", line.contains(secret))
        }
    }

    @Test fun theWebSocketClientIsOurOwnWithNoNewLibrary() {
        // Decision D2 of android/RELAY_PLAN.md: no WebSocket library; OkHttp stays the fallback if this client ever proves unreliable.
        val gradle = File("build.gradle.kts").readText().lowercase()
        for (lib in listOf("okhttp", "tyrus", "java-websocket", "scarlet", "ktor")) assertFalse("$lib was added", gradle.contains(lib))
    }

    @Test fun theRelayPairingKeepsItsSecretsOutOfToString() {
        val r = RelayPairing("wss://relay.example.com", "R", "K", "A")
        assertTrue(r.toString() == "RelayPairing(..)")
    }

    @Test fun theSecureStoreKeepsEverythingInsideTheEncryptedBlob() {
        val store = main("app/SecureStore.kt")
        // The pairing, relay fields included, goes through one encrypted preference and nothing else is written for it.
        assertTrue(store.contains("PairingCodec.encode(p)"))
        assertTrue(Regex("""putString\(""").findAll(store).count() == 1)
    }
}
