package com.coucou.android.link

import java.io.IOException
import java.net.Socket

/** Which way the link reaches the computer. */
enum class Route { LAN, RELAY }

/**
 * The rules for choosing between the direct link on the local network (fast, private to the network) and the relay
 * (works from anywhere). Pure: the clock is injected, so the rules are tested without a network.
 *
 *  - Without a relay, only the LAN is ever tried.
 *  - With one, the LAN is tried first with a short timeout, and the relay only when the LAN did not answer.
 *  - Having just found the LAN unreachable, the next reconnects go to the relay first for [LAN_SKIP_MS] (so a phone that is away
 *    does not wait out a LAN timeout every time), with the LAN as the fallback if the relay fails too.
 *  - While connected through the relay, the LAN is tried again every [LAN_PROBE_MS] and the link moves back to it.
 */
class TransportPolicy(
    private val relayConfigured: () -> Boolean,
    private val clockMs: () -> Long = System::currentTimeMillis,
) {
    @Volatile private var lanFailedAt: Long = NEVER
    /** The routes to try now, in order. */
    fun order(): List<Route> {
        if (!relayConfigured()) return listOf(Route.LAN)
        val recently = lanFailedAt != NEVER && clockMs() - lanFailedAt in 0 until LAN_SKIP_MS
        return if (recently) listOf(Route.RELAY, Route.LAN) else listOf(Route.LAN, Route.RELAY)
    }

    /** How long the LAN gets before it counts as failed: shorter when there is a relay to fall back on. */
    fun lanTimeoutMs(requestedMs: Int): Int = if (relayConfigured()) minOf(requestedMs, LAN_FAST_MS) else requestedMs

    fun lanFailed() { lanFailedAt = clockMs() }
    fun lanWorked() { lanFailedAt = NEVER }

    companion object {
        const val LAN_FAST_MS = 2_500
        const val LAN_SKIP_MS = 60_000L
        const val LAN_PROBE_MS = 90_000L
        private const val NEVER = Long.MIN_VALUE
    }
}

/**
 * The [Connector] the [LinkClient] uses when a pairing has a relay: tries the routes in the policy's order, and while on the
 * relay looks for the LAN from time to time and moves back to it. [onRoute] says which way is in use (for the status line).
 */
class FallbackConnector(
    private val lan: Connector,
    private val relay: Connector,
    private val policy: TransportPolicy,
    private val onRoute: (Route) -> Unit = {},
    private val probeEveryMs: Long = TransportPolicy.LAN_PROBE_MS,
    private val probeTimeoutMs: Int = TransportPolicy.LAN_FAST_MS,
) : Connector {
    @Volatile var route: Route? = null
        private set
    @Volatile private var probe: Thread? = null
    @Volatile private var relaySocket: Socket? = null

    override fun connect(timeoutMs: Int): Socket {
        var failure: IOException? = null
        for (r in policy.order()) {
            try {
                val s = when (r) {
                    Route.LAN -> lan.connect(policy.lanTimeoutMs(timeoutMs)).also { policy.lanWorked() }
                    Route.RELAY -> relay.connect(timeoutMs)
                }
                route = r
                onRoute(r)
                if (r == Route.RELAY) {
                    relaySocket = s
                    watchForLan(s)
                }
                return s
            } catch (e: IOException) {
                if (r == Route.LAN) policy.lanFailed()
                failure = failure ?: e
            }
        }
        throw failure ?: IOException("no route")
    }

    /** While [relaySocket] is open, tries the LAN every so often; when it answers, drops the relay so the link reconnects direct. */
    private fun watchForLan(relaySocket: Socket) {
        probe?.interrupt()
        probe = Thread({
            try {
                while (!relaySocket.isClosed) {
                    Thread.sleep(probeEveryMs)
                    if (relaySocket.isClosed) break
                    if (lanAnswers()) {
                        policy.lanWorked()
                        runCatching { relaySocket.close() }
                        break
                    }
                }
            } catch (_: InterruptedException) {
            }
        }, "coucou-lan-probe").apply { isDaemon = true; start() }
    }

    /** One bare attempt at the LAN link (the pinned TLS handshake), closed again at once. */
    fun lanAnswers(): Boolean = try {
        lan.connect(probeTimeoutMs).close()
        true
    } catch (_: IOException) {
        false
    }

    /** The network changed while on the relay: look for the LAN now instead of waiting for the next probe. */
    fun networkChanged() {
        val s = relaySocket ?: return
        if (s.isClosed) return
        Thread({
            if (!s.isClosed && lanAnswers()) {
                policy.lanWorked()
                runCatching { s.close() } // the link reconnects, and tries the LAN first
            }
        }, "coucou-lan-check").apply { isDaemon = true; start() }
    }

    fun stop() {
        probe?.interrupt()
        probe = null
    }
}
