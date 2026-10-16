package com.coucou.android.link

import java.io.IOException
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** LAN first, relay when the LAN does not answer, and back to the LAN when it does again. */
class TransportTest {
    private var now = 1_000_000L
    private var relayOn = true
    private val policy = TransportPolicy({ relayOn }, { now })

    @Test fun withoutARelayOnlyTheLanIsEverTried() {
        relayOn = false
        assertEquals(listOf(Route.LAN), policy.order())
        policy.lanFailed()
        assertEquals(listOf(Route.LAN), policy.order())
        assertEquals(5_000, policy.lanTimeoutMs(5_000))
    }

    @Test fun withARelayTheLanComesFirstWithAShortTimeout() {
        assertEquals(listOf(Route.LAN, Route.RELAY), policy.order())
        assertEquals(TransportPolicy.LAN_FAST_MS, policy.lanTimeoutMs(10_000))
        assertEquals(1_000, policy.lanTimeoutMs(1_000))
    }

    @Test fun afterALanFailureTheRelayIsTriedFirstForAWhileThenTheLanAgain() {
        policy.lanFailed()
        assertEquals(listOf(Route.RELAY, Route.LAN), policy.order())
        now += TransportPolicy.LAN_SKIP_MS - 1
        assertEquals(listOf(Route.RELAY, Route.LAN), policy.order())
        now += 1
        assertEquals(listOf(Route.LAN, Route.RELAY), policy.order())
    }

    @Test fun aLanSuccessForgetsTheFailure() {
        policy.lanFailed()
        policy.lanWorked()
        assertEquals(listOf(Route.LAN, Route.RELAY), policy.order())
    }

    // ── the connector on top of the policy ──

    private class FakeSocket : Socket()

    private class Fake(private val works: () -> Boolean) : Connector {
        val calls = AtomicInteger()
        val timeouts = mutableListOf<Int>()
        val made = mutableListOf<Socket>()
        override fun connect(timeoutMs: Int): Socket {
            calls.incrementAndGet()
            timeouts += timeoutMs
            if (!works()) throw IOException("down")
            return FakeSocket().also { made += it }
        }
    }

    private fun connector(lan: Fake, relay: Fake, routes: MutableList<Route> = mutableListOf(), every: Long = 3_600_000) =
        FallbackConnector(lan, relay, policy, { routes += it }, probeEveryMs = every, probeTimeoutMs = 200)

    @Test fun theLanIsUsedWhenItAnswers() {
        val lan = Fake { true }
        val relay = Fake { true }
        val routes = mutableListOf<Route>()
        val c = connector(lan, relay, routes)
        val s = c.connect(10_000)
        assertSame(lan.made.single(), s)
        assertEquals(0, relay.calls.get())
        assertEquals(listOf(Route.LAN), routes)
        assertEquals(TransportPolicy.LAN_FAST_MS, lan.timeouts.single())
    }

    @Test fun theRelayIsUsedWhenTheLanDoesNotAnswer() {
        val lan = Fake { false }
        val relay = Fake { true }
        val routes = mutableListOf<Route>()
        val c = connector(lan, relay, routes)
        val s = c.connect(10_000)
        assertSame(relay.made.single(), s)
        assertEquals(listOf(Route.RELAY), routes)
        assertEquals(Route.RELAY, c.route)
        c.stop()
        // The next attempt goes to the relay first, without waiting for a LAN timeout.
        c.connect(10_000)
        assertEquals("the LAN was not tried again within the window", 1, lan.calls.get())
    }

    @Test fun whenBothFailTheFirstFailureIsReported() {
        val c = connector(Fake { false }, Fake { false })
        try { c.connect(1_000); fail() } catch (e: IOException) { assertEquals("down", e.message) }
    }

    @Test fun ifTheRelayFailsInsideTheSkipWindowTheLanGetsAnotherChance() {
        val lanUp = AtomicBoolean(false)
        val lan = Fake { lanUp.get() }
        val relay = Fake { false }
        val c = connector(lan, relay)
        try { c.connect(1_000); fail() } catch (_: IOException) {}
        lanUp.set(true) // back home, inside the 60 s window
        val s = c.connect(1_000)
        assertSame(lan.made.last(), s)
        assertEquals(Route.LAN, c.route)
    }

    @Test fun whileOnTheRelayAFoundLanEndsTheRelayConnectionSoTheLinkMovesBack() {
        val lanUp = AtomicBoolean(false)
        val lan = Fake { lanUp.get() }
        val relay = Fake { true }
        val c = connector(lan, relay, every = 40)
        val relaySocket = c.connect(1_000)
        assertFalse(relaySocket.isClosed)
        lanUp.set(true)
        val deadline = System.currentTimeMillis() + 3_000
        while (!relaySocket.isClosed && System.currentTimeMillis() < deadline) Thread.sleep(10)
        assertTrue("the relay socket was closed once the LAN answered", relaySocket.isClosed)
        c.stop()
    }

    @Test fun aNetworkChangeLooksForTheLanAtOnce() {
        val lanUp = AtomicBoolean(false)
        val lan = Fake { lanUp.get() }
        val c = connector(lan, Fake { true })
        val relaySocket = c.connect(1_000)
        c.networkChanged()
        Thread.sleep(150)
        assertFalse("the LAN is still down: stay", relaySocket.isClosed)
        lanUp.set(true)
        c.networkChanged()
        val deadline = System.currentTimeMillis() + 3_000
        while (!relaySocket.isClosed && System.currentTimeMillis() < deadline) Thread.sleep(10)
        assertTrue(relaySocket.isClosed)
        c.stop()
    }

    @Test fun theProbeConnectionItselfIsClosedAgain() {
        val lan = Fake { true }
        val c = connector(lan, Fake { true })
        assertTrue(c.lanAnswers())
        assertTrue(lan.made.single().isClosed)
    }
}
