package com.coucou.android.link

import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.security.SecureRandom
import javax.net.ssl.SSLContext

/**
 * Finding the paired computer again when its address changed (another Wi-Fi, a hotspot). The computer announces
 * `_coucou._tcp` on the local network while its phone link is on (docs/ANDROID_LINK.md, "Finding the computer").
 *
 * The announcement is a hint, never a credential: it carries the protocol version and the first 16 hex characters of the
 * certificate's SHA-256. The phone matches on that id, then checks the **full** pinned certificate with a bare TLS
 * handshake (no token is sent) before it saves the new address. A lookalike cannot get the token.
 */

/** A computer seen on the local network. */
data class Found(val name: String, val host: String, val port: Int, val fingerprintId: String?, val version: String?)

enum class DiscoveryState { IDLE, LOOKING, NOT_FOUND }

enum class ProbeResult { MATCH, PIN_MISMATCH, UNREACHABLE }

/**
 * Checks that [host]:[port] presents the pinned certificate, by TLS handshake only. It takes no token on purpose:
 * nothing secret can be sent, whatever answers.
 */
fun interface Probe { fun check(host: String, port: Int, certSha256: String): ProbeResult }

/** Where services come from: the system's NsdManager in the app, a fake in tests. */
interface DiscoverySource {
    fun start(onFound: (Found) -> Unit)
    fun stop()
}

object Discovery {
    const val SERVICE_TYPE = "_coucou._tcp"
    const val FP_ID_LEN = 16
    const val TXT_VERSION = "1"
    const val DEFAULT_PORT = 47821

    /** The short id of a certificate fingerprint (first 16 lowercase hex), or null if it is not hex. */
    fun fingerprintId(sha256Hex: String): String? {
        val f = sha256Hex.trim().lowercase()
        if (f.length < FP_ID_LEN || !f.all { it in '0'..'9' || it in 'a'..'f' }) return null
        return f.substring(0, FP_ID_LEN)
    }

    /** The only rule for "this is my computer": same fingerprint id, and a protocol version we speak. Name and address never count. */
    fun matches(f: Found, p: PairingPayload): Boolean {
        val mine = fingerprintId(p.certSha256) ?: return false
        val theirs = f.fingerprintId?.trim()?.lowercase() ?: return false
        return theirs == mine && (f.version == null || f.version == TXT_VERSION)
    }

    /** An IPv4 literal on the local network: private, link-local or loopback. The computer refuses every other peer too. */
    fun isLocalHost(host: String): Boolean {
        val o = ipv4(host) ?: return false
        return o[0] == 10 || (o[0] == 172 && o[1] in 16..31) || (o[0] == 192 && o[1] == 168) ||
            (o[0] == 169 && o[1] == 254) || o[0] == 127 || (o[0] == 100 && o[1] in 64..127)
    }

    private fun ipv4(host: String): IntArray? {
        val parts = host.split(".")
        if (parts.size != 4) return null
        val n = parts.map { it.takeIf { s -> s.isNotEmpty() && s.length <= 3 && s.all(Char::isDigit) }?.toInt() ?: return null }
        return if (n.all { it in 0..255 }) n.toIntArray() else null
    }

    /** The services worth checking, in the order they were seen: matching, on the local network, no duplicate address. */
    fun candidates(seen: List<Found>, p: PairingPayload): List<Found> =
        seen.filter { matches(it, p) && isLocalHost(it.host) && it.port in 1..65535 }.distinctBy { it.host to it.port }

    /** The pairing with a new address. The token and the pinned fingerprint are the same objects, untouched. */
    fun withAddress(p: PairingPayload, host: String, port: Int): PairingPayload = p.copy(host = host, port = port)

    /** "192.168.1.20", "192.168.1.20:47821" or "my-pc.local:47821"; the port defaults to 47821. Null if it cannot be an address. */
    fun parseAddress(text: String): Pair<String, Int>? {
        val t = text.trim()
        if (t.isEmpty() || t.any { it.isWhitespace() } || t.contains("/") || t.contains("@") || t.contains("[")) return null
        val colon = t.lastIndexOf(':')
        val host = if (colon >= 0) t.substring(0, colon) else t
        val port = if (colon >= 0) t.substring(colon + 1).takeIf { it.isNotEmpty() && it.length <= 5 && it.all(Char::isDigit) }?.toInt() ?: return null else DEFAULT_PORT
        if (port !in 1..65535 || host.isEmpty() || host.contains(":")) return null
        val looksNumeric = host.all { it.isDigit() || it == '.' }
        val ok = if (looksNumeric) ipv4(host) != null else host.length <= 253 && host.split(".").all { label ->
            label.isNotEmpty() && label.length <= 63 && label.all { it.isLetterOrDigit() || it == '-' } && !label.startsWith("-") && !label.endsWith("-")
        }
        return if (ok) host to port else null
    }
}

/** When and how long to look. Pure numbers, so the battery rules are tests. */
object DiscoveryPolicy {
    /** The saved address is tried first and given this long to answer (TCP connect). */
    const val SAVED_CONNECT_TIMEOUT_MS = 2_000
    /** The saved address must fail this many times in a row before the network is searched. */
    const val FAILURES_BEFORE_DISCOVERY = 1
    /** One search lasts this long. If nothing is found the calm hint appears. */
    const val WINDOW_MS = 15_000L
    /** Wait before search number n (0 = right away). It never gets faster, and never slower than 5 minutes. */
    private val ROUND_DELAYS_MS = longArrayOf(0, 20_000, 60_000, 180_000, 300_000)

    fun delayBeforeRound(round: Int): Long = ROUND_DELAYS_MS[round.coerceIn(0, ROUND_DELAYS_MS.size - 1)]

    /** Searching costs battery: only when there is a computer to find, on a Wi-Fi (or cable), and the link is not up. */
    fun mayDiscover(paired: Boolean, demo: Boolean, wifiUp: Boolean, linkConnected: Boolean): Boolean =
        paired && !demo && wifiUp && !linkConnected
}

fun interface Cancelable { fun cancel() }

fun interface Scheduler { fun after(delayMs: Long, task: () -> Unit): Cancelable }

fun interface Runner { fun run(task: () -> Unit) }

/**
 * One search at a time: browse for the service, check each matching one with the [Probe], and hand the first that
 * passes to [onAddress]. After a search that finds nothing it waits longer and longer before the next. All state
 * changes happen under one lock; probes run on [runner], never on the browsing callback's thread.
 */
class AddressFinder(
    private val source: DiscoverySource,
    private val probe: Probe,
    private val pairing: () -> PairingPayload?,
    private val allowed: () -> Boolean,
    private val onAddress: (host: String, port: Int) -> Unit,
    private val onState: (DiscoveryState) -> Unit,
    private val scheduler: Scheduler,
    private val runner: Runner,
) {
    private val lock = Any()
    private var state = DiscoveryState.IDLE
    private var round = 0
    private var window: Cancelable? = null
    private var waiting: Cancelable? = null
    private val seen = HashSet<String>()
    /** Addresses whose certificate did not match this search: dropped, never tried again until the next search. */
    private val rejected = HashSet<String>()

    val current: DiscoveryState get() = synchronized(lock) { state }

    /** Starts a search unless one is running or the next is already scheduled. */
    fun request() {
        synchronized(lock) {
            if (state == DiscoveryState.LOOKING || waiting != null) return
            beginRound()
        }
    }

    /** The network changed: forget the waiting, search now. */
    fun networkChanged() {
        synchronized(lock) {
            waiting?.cancel(); waiting = null
            if (state == DiscoveryState.LOOKING) return
            round = 0
            beginRound()
        }
    }

    /** The link is up: nothing more to find. */
    fun connected() { synchronized(lock) { halt() } }

    fun stop() { synchronized(lock) { halt() } }

    private fun halt() {
        window?.cancel(); window = null
        waiting?.cancel(); waiting = null
        runCatching { source.stop() }
        round = 0
        setState(DiscoveryState.IDLE)
    }

    private fun beginRound() {
        if (!allowed() || pairing() == null) { setState(DiscoveryState.IDLE); return }
        seen.clear(); rejected.clear()
        setState(DiscoveryState.LOOKING)
        window = scheduler.after(DiscoveryPolicy.WINDOW_MS) { endRound() }
        source.start { f -> runner.run { handle(f) } }
    }

    private fun endRound() {
        synchronized(lock) {
            if (state != DiscoveryState.LOOKING) return
            window = null
            runCatching { source.stop() }
            setState(DiscoveryState.NOT_FOUND)
            round++
            waiting = scheduler.after(DiscoveryPolicy.delayBeforeRound(round)) {
                synchronized(lock) { waiting = null; if (state == DiscoveryState.NOT_FOUND) beginRound() }
            }
        }
    }

    private fun handle(f: Found) {
        val p: PairingPayload
        val key = "${f.host}:${f.port}"
        synchronized(lock) {
            if (state != DiscoveryState.LOOKING) return
            p = pairing() ?: return
            if (Discovery.candidates(listOf(f), p).isEmpty() || key in rejected || !seen.add(key)) return
        }
        // The check is a network handshake: outside the lock. It carries no token.
        val result = try { probe.check(f.host, f.port, p.certSha256) } catch (_: Exception) { ProbeResult.UNREACHABLE }
        synchronized(lock) {
            if (state != DiscoveryState.LOOKING) return
            when (result) {
                ProbeResult.MATCH -> {
                    window?.cancel(); window = null
                    runCatching { source.stop() }
                    round = 0
                    setState(DiscoveryState.IDLE)
                    onAddress(f.host, f.port)
                }
                ProbeResult.PIN_MISMATCH -> rejected.add(key) // a lookalike: dropped
                ProbeResult.UNREACHABLE -> seen.remove(key) // may be announced again
            }
        }
    }

    private fun setState(s: DiscoveryState) {
        if (state == s) return
        state = s
        onState(s)
    }
}

/** The real [Probe]: a TLS handshake against the pinned certificate, then close. The token is never involved. */
object PinnedProbe : Probe {
    override fun check(host: String, port: Int, certSha256: String): ProbeResult {
        val ctx = SSLContext.getInstance("TLS").apply { init(null, arrayOf(PinnedTrustManager(certSha256)), SecureRandom()) }
        val raw = Socket()
        return try {
            raw.connect(InetSocketAddress(host, port), 2_000)
            val tls = ctx.socketFactory.createSocket(raw, host, port, true) as javax.net.ssl.SSLSocket
            tls.enabledProtocols = tls.supportedProtocols.filter { it == "TLSv1.3" || it == "TLSv1.2" }.toTypedArray()
            tls.soTimeout = 5_000
            tls.startHandshake()
            ProbeResult.MATCH
        } catch (e: javax.net.ssl.SSLException) {
            if (generateSequence<Throwable>(e) { it.cause }.any { it is java.security.cert.CertificateException }) ProbeResult.PIN_MISMATCH
            else ProbeResult.UNREACHABLE
        } catch (_: IOException) {
            ProbeResult.UNREACHABLE
        } finally {
            runCatching { raw.close() }
        }
    }
}
