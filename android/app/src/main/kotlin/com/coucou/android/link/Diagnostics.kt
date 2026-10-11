package com.coucou.android.link

import java.io.IOException
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.net.URL
import javax.net.ssl.SSLException

/** The questions "Can't connect?" asks, in the order that makes each answer meaningful. */
enum class DiagStep(val title: String) {
    NETWORK("Phone network"),
    ADDRESS("Saved address answers"),
    DISCOVERY("Computer announces itself"),
    SECURE("Secure connection (pinned certificate)"),
    TOKEN("Pairing code and version"),
    RELAY("Relay"),
}

sealed class DiagResult {
    /** [detail] says what was seen in a few words. */
    data class Ok(val detail: String) : DiagResult()
    /** [problem] is what is wrong; [hint] is what to try, calmly. */
    data class Problem(val problem: String, val hint: String) : DiagResult()
    /** Not asked, because a step before it already failed. */
    data class Skipped(val why: String) : DiagResult()
}

/** What the checks need from the phone; the real one is [LanDiagnostics], tests use fakes. */
interface DiagEnv {
    fun network(): DiagResult
    fun address(): DiagResult
    fun discovery(): DiagResult
    fun secure(): DiagResult
    fun token(): DiagResult
    /** Null when the pairing has no relay. */
    fun relay(): DiagResult?
}

object Diagnostics {
    /** Runs every check, reporting each as it finishes. A step whose premise failed is skipped, not guessed. */
    fun run(env: DiagEnv, onResult: (DiagStep, DiagResult) -> Unit = { _, _ -> }): List<Pair<DiagStep, DiagResult>> {
        val out = ArrayList<Pair<DiagStep, DiagResult>>()
        fun put(step: DiagStep, r: DiagResult) { out += step to r; onResult(step, r) }
        fun failed(step: DiagStep) = out.any { it.first == step && it.second !is DiagResult.Ok }

        put(DiagStep.NETWORK, safe { env.network() })
        put(DiagStep.ADDRESS, if (failed(DiagStep.NETWORK)) DiagResult.Skipped("Needs the Wi-Fi") else safe { env.address() })
        put(DiagStep.DISCOVERY, if (failed(DiagStep.NETWORK)) DiagResult.Skipped("Needs the Wi-Fi") else safe { env.discovery() })
        put(DiagStep.SECURE, if (failed(DiagStep.ADDRESS)) DiagResult.Skipped("Needs the address to answer") else safe { env.secure() })
        put(DiagStep.TOKEN, if (failed(DiagStep.ADDRESS) || failed(DiagStep.SECURE)) DiagResult.Skipped("Needs the secure connection") else safe { env.token() })
        try { env.relay() } catch (e: Exception) { broken(e) }?.let { put(DiagStep.RELAY, it) }
        return out
    }

    private fun broken(e: Exception) = DiagResult.Problem("The check itself failed (${e.javaClass.simpleName})", "Try again.")

    private fun safe(f: () -> DiagResult): DiagResult = try { f() } catch (e: Exception) { broken(e) }

    /** "192.168.1.20" -> "192.168.x.x": enough to tell a home network from a hotspot, not enough to find a house. */
    fun maskHost(host: String): String {
        val parts = host.split(".")
        return if (parts.size == 4 && parts.all { p -> p.isNotEmpty() && p.all(Char::isDigit) }) "${parts[0]}.${parts[1]}.x.x" else "a name (hidden)"
    }

    /**
     * The report the user can copy and send. It names the checks and what they found; it never contains the pairing code,
     * the certificate fingerprint, the computer's name, the full address or any key.
     */
    fun report(appVersion: String, androidVersion: String, device: String, results: List<Pair<DiagStep, DiagResult>>, hostMasked: String, via: String): String =
        buildString {
            appendLine("Coucou for Android $appVersion · Android $androidVersion · $device")
            appendLine("Computer: $hostMasked · connected via: $via")
            for ((step, r) in results) {
                appendLine(
                    when (r) {
                        is DiagResult.Ok -> "OK       ${step.title}: ${r.detail}"
                        is DiagResult.Problem -> "PROBLEM  ${step.title}: ${r.problem}"
                        is DiagResult.Skipped -> "SKIPPED  ${step.title}: ${r.why}"
                    },
                )
            }
        }.trimEnd()
}

/**
 * The real checks against one pairing. Plain JVM except what the phone supplies: whether Wi-Fi is up, and a way to look the computer
 * up on the network ([discover]). The pairing code is used only to say hello, as the app does; it is never put in a result.
 */
class LanDiagnostics(
    private val p: PairingPayload,
    private val wifiUp: () -> Boolean,
    private val onCellular: () -> Boolean,
    private val discover: () -> List<Found>,
    private val connector: Connector = PinnedTls.connector(p),
    private val relayCheck: (() -> DiagResult)? = null,
    private val timeoutMs: Int = 3_000,
) : DiagEnv {
    override fun network(): DiagResult = when {
        wifiUp() -> DiagResult.Ok("Wi-Fi is connected")
        p.relay != null && onCellular() -> DiagResult.Ok("Mobile data (the relay can be used; the direct link needs the home Wi-Fi)")
        else -> DiagResult.Problem("The phone is not on a Wi-Fi network", "Join the same Wi-Fi as your computer, or turn on Away from home Wi-Fi to use the relay.")
    }

    override fun address(): DiagResult {
        val started = System.nanoTime()
        val s = Socket()
        return try {
            s.connect(InetSocketAddress(p.host, p.port), timeoutMs)
            DiagResult.Ok("Answers in ${(System.nanoTime() - started) / 1_000_000} ms at ${Diagnostics.maskHost(p.host)}")
        } catch (_: SocketTimeoutException) {
            DiagResult.Problem(
                "No answer from ${Diagnostics.maskHost(p.host)}",
                "Is the computer on and Coucou running with the Phone link switched on? Same Wi-Fi? A guest network or client isolation blocks it.",
            )
        } catch (_: IOException) {
            DiagResult.Problem("Cannot reach ${Diagnostics.maskHost(p.host)}", "The computer may have a new address: see the next line, or type the address in Home.")
        } finally {
            runCatching { s.close() }
        }
    }

    override fun discovery(): DiagResult {
        val found = Discovery.candidates(discover(), p)
        return when {
            found.isEmpty() -> DiagResult.Problem(
                "The computer is not announcing itself here",
                "Some networks block this. If the saved address answers, you can ignore it; otherwise type the address in Home.",
            )
            found.any { it.host == p.host && it.port == p.port } -> DiagResult.Ok("Found, same address as the saved one")
            else -> DiagResult.Problem("Found at ${Diagnostics.maskHost(found.first().host)}, not at the saved address", "Open Home: the phone updates the address by itself when it is not connected.")
        }
    }

    override fun secure(): DiagResult = try {
        connector.connect(timeoutMs).close()
        DiagResult.Ok("The computer's certificate is the one you paired with")
    } catch (e: SSLException) {
        if (generateSequence<Throwable>(e) { it.cause }.any { it is java.security.cert.CertificateException }) {
            DiagResult.Problem("This is not the computer you paired with (its certificate differs)", "Coucou may have been reinstalled, or this is another computer. Pair again.")
        } else {
            DiagResult.Problem("The secure handshake failed", "Try again. If it keeps failing, pair again.")
        }
    } catch (_: IOException) {
        DiagResult.Problem("The secure connection could not be opened", "The address answers but nothing speaks Coucou there. Is the Phone link switched on?")
    }

    override fun token(): DiagResult {
        val s = try {
            connector.connect(timeoutMs)
        } catch (_: IOException) {
            return DiagResult.Problem("Could not connect to say hello", "See the lines above.")
        }
        return try {
            s.soTimeout = 5_000
            s.getOutputStream().apply { write((Wire.encode(ClientMsg.Hello(Protocol.VERSION, p.token, "Diagnostics", emptyList())) + "\n").toByteArray()); flush() }
            val line = readLine(s) ?: return DiagResult.Problem("The computer closed the connection at once", "Try again.")
            when (val m = Wire.decodeServer(line)) {
                is ServerMsg.Welcome ->
                    if (m.version == Protocol.VERSION) DiagResult.Ok("Pairing code accepted, protocol version ${m.version}")
                    else DiagResult.Problem("The computer speaks version ${m.version}, this app speaks ${Protocol.VERSION}", "Update Coucou on the computer or the app.")
                is ServerMsg.Error ->
                    if (m.code == "auth") DiagResult.Problem("The pairing code was refused", "The computer made a new code (Pair again). Scan its new code.")
                    else DiagResult.Problem("The computer answered with an error (${m.code})", "Try again.")
                else -> DiagResult.Problem("An unexpected answer to hello", "Update Coucou on the computer and the app.")
            }
        } catch (_: SocketTimeoutException) {
            DiagResult.Problem("No answer to hello", "The computer is busy or asleep. Try again.")
        } catch (_: IOException) {
            DiagResult.Problem("The connection broke while saying hello", "Try again.")
        } finally {
            runCatching { s.getOutputStream().apply { write((Wire.encode(ClientMsg.Bye) + "\n").toByteArray()); flush() } }
            runCatching { s.close() }
        }
    }

    override fun relay(): DiagResult? = relayCheck?.invoke()

    private fun readLine(s: Socket): String? {
        val b = java.io.ByteArrayOutputStream()
        while (b.size() < Protocol.MAX_LINE_BYTES) {
            val x = s.getInputStream().read()
            if (x < 0) return null
            if (x == '\n'.code) return b.toString("UTF-8")
            b.write(x)
        }
        return null
    }

    companion object {
        /**
         * The relay answers `GET /` with "Coucou link relay" without a key and without touching any room, so this check can never
         * replace the phone's live connection (joining a room as the phone would).
         */
        fun relayReachable(relay: RelayPairing, timeoutMs: Int = 5_000): DiagResult {
            val url = relay.relayUrl() ?: return DiagResult.Problem("The relay address in the pairing is not valid", "Pair again.")
            return try {
                val conn = URL("${if (url.tls) "https" else "http"}://${url.host}:${url.port}/").openConnection() as HttpURLConnection
                conn.connectTimeout = timeoutMs
                conn.readTimeout = timeoutMs
                conn.instanceFollowRedirects = false
                val body = try { conn.inputStream.bufferedReader().readText().take(64) } finally { conn.disconnect() }
                if (conn.responseCode == 200 && body.startsWith("Coucou link relay")) DiagResult.Ok("The relay at ${url.host} answers")
                else DiagResult.Problem("${url.host} answers but is not a Coucou relay", "Check the address on the computer (Away from home Wi-Fi).")
            } catch (_: IOException) {
                DiagResult.Problem("Cannot reach the relay at ${url.host}", "Check your internet connection and the relay's address.")
            }
        }
    }
}
