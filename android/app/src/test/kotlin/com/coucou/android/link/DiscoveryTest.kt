package com.coucou.android.link

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private const val CERT = "ab12cd34ef56ab78901234567890abcdef1234567890abcdef1234567890abcd"
private const val OTHER_CERT = "ab12cd34ef56ab78ffffffffffffffffffffffffffffffffffffffffffffffff" // same first 16: a lookalike
private const val TOKEN = "secret_token_1234567"

private fun paired(host: String = "192.168.10.6", port: Int = 47821) =
    PairingPayload(host, port, CERT, TOKEN, "My PC")

private fun found(host: String, id: String? = "ab12cd34ef56ab78", port: Int = 47821, name: String = "My PC", v: String? = "1") =
    Found(name, host, port, id, v)

class DiscoveryMatchingTest {
    @Test fun theIdIsTheFirstSixteenHexOfTheCertificate() {
        assertEquals("ab12cd34ef56ab78", Discovery.fingerprintId(CERT))
        assertEquals("ab12cd34ef56ab78", Discovery.fingerprintId(CERT.uppercase()))
        assertNull(Discovery.fingerprintId("not hex at all, long enough"))
        assertNull(Discovery.fingerprintId("abcd"))
    }

    @Test fun onlyTheFingerprintIdDecidesWhoIsMyComputer() {
        val p = paired()
        assertTrue(Discovery.matches(found("10.154.121.113"), p))
        assertTrue("the name does not matter", Discovery.matches(found("10.154.121.113", name = "Something else"), p))
        assertFalse("another computer", Discovery.matches(found("10.154.121.113", id = "0000000000000000"), p))
        assertFalse("no id announced", Discovery.matches(found("10.154.121.113", id = null), p))
        assertFalse("same name, other id", Discovery.matches(found("10.154.121.113", id = "ffffffffffffffff", name = "My PC"), p))
    }

    @Test fun aVersionWeDoNotSpeakIsNotAMatch() {
        assertTrue(Discovery.matches(found("10.0.0.5", v = null), paired()))
        assertFalse(Discovery.matches(found("10.0.0.5", v = "2"), paired()))
    }

    @Test fun twoComputersThatMatchNoFingerprintGiveNoCandidate() {
        val seen = listOf(found("192.168.1.5", id = "1111111111111111", name = "PC A"), found("192.168.1.6", id = "2222222222222222", name = "PC B"))
        assertTrue(Discovery.candidates(seen, paired()).isEmpty())
    }

    @Test fun theSamePairedFingerprintTwiceKeepsBothInOrderWithoutDuplicates() {
        val seen = listOf(found("192.168.1.5"), found("192.168.1.5"), found("10.0.0.9"))
        assertEquals(listOf("192.168.1.5", "10.0.0.9"), Discovery.candidates(seen, paired()).map { it.host })
    }

    @Test fun onlyLocalAddressesAreEverTried() {
        for (ok in listOf("192.168.0.2", "10.154.121.113", "172.16.5.5", "172.31.255.1", "169.254.3.4", "127.0.0.1", "100.64.1.1")) assertTrue(ok, Discovery.isLocalHost(ok))
        for (bad in listOf("8.8.8.8", "172.32.0.1", "192.169.0.1", "100.128.0.1", "example.com", "1.2.3", "256.1.1.1", "", "fe80::1")) assertFalse(bad, Discovery.isLocalHost(bad))
        assertTrue(Discovery.candidates(listOf(found("8.8.8.8")), paired()).isEmpty())
    }

    @Test fun anAddressChangeKeepsTheTokenAndThePinnedCertificate() {
        val p = paired()
        val q = Discovery.withAddress(p, "10.154.121.113", 47900)
        assertEquals("10.154.121.113", q.host)
        assertEquals(47900, q.port)
        assertEquals(p.token, q.token)
        assertEquals(p.certSha256, q.certSha256)
        assertEquals(p.desktopName, q.desktopName)
    }
}

class AddressParsingTest {
    @Test fun anAddressWithOrWithoutAPort() {
        assertEquals("192.168.1.20" to 47821, Discovery.parseAddress("192.168.1.20"))
        assertEquals("192.168.1.20" to 5000, Discovery.parseAddress(" 192.168.1.20:5000 "))
        assertEquals("my-pc.local" to 47821, Discovery.parseAddress("my-pc.local"))
        assertEquals("my-pc.local" to 1, Discovery.parseAddress("my-pc.local:1"))
    }

    @Test fun thingsThatCannotBeAnAddressAreRefused() {
        for (bad in listOf("", "  ", "192.168.1", "256.1.1.1", "192.168.1.20:0", "192.168.1.20:70000", "192.168.1.20:", "host:abc", "a b", "http://x", "x/y", "user@host", "[::1]:47821", "::1", "-bad.local", "a..b", "host:1:2")) {
            assertNull("'$bad'", Discovery.parseAddress(bad))
        }
    }
}

class DiscoveryPolicyTest {
    @Test fun theSavedAddressGetsTwoSecondsAndOneFailureBeforeTheNetworkIsSearched() {
        assertEquals(2_000, DiscoveryPolicy.SAVED_CONNECT_TIMEOUT_MS)
        assertEquals(1, DiscoveryPolicy.FAILURES_BEFORE_DISCOVERY)
        assertEquals(15_000L, DiscoveryPolicy.WINDOW_MS)
    }

    @Test fun backoffNeverSpeedsUpAndStopsAtFiveMinutes() {
        val delays = (0..12).map { DiscoveryPolicy.delayBeforeRound(it) }
        assertEquals(0L, delays[0])
        assertEquals(delays.sorted(), delays)
        assertEquals(300_000L, delays.last())
        assertEquals(0L, DiscoveryPolicy.delayBeforeRound(-3))
    }

    @Test fun nothingIsSearchedWhenConnectedOrWithoutWifiOrWithoutAComputerOrInTheDemo() {
        assertTrue(DiscoveryPolicy.mayDiscover(paired = true, demo = false, wifiUp = true, linkConnected = false))
        assertFalse(DiscoveryPolicy.mayDiscover(paired = true, demo = false, wifiUp = true, linkConnected = true))
        assertFalse(DiscoveryPolicy.mayDiscover(paired = true, demo = false, wifiUp = false, linkConnected = false))
        assertFalse(DiscoveryPolicy.mayDiscover(paired = false, demo = false, wifiUp = true, linkConnected = false))
        assertFalse(DiscoveryPolicy.mayDiscover(paired = true, demo = true, wifiUp = true, linkConnected = false))
    }
}

/** A fake clock that runs scheduled tasks when time is moved, and a fake network source: no real network anywhere. */
private class Fixture(var pairing: PairingPayload? = paired(), var allowed: Boolean = true) {
    class Task(val at: Long, val task: () -> Unit) : Cancelable { var live = true; override fun cancel() { live = false } }
    var now = 0L
    val tasks = ArrayList<Task>()
    val scheduler = Scheduler { d, t -> Task(now + d, t).also { tasks.add(it) } }
    fun advance(ms: Long) {
        val end = now + ms
        while (true) {
            val next = tasks.filter { it.live && it.at <= end }.minByOrNull { it.at } ?: break
            now = next.at; next.live = false; next.task()
        }
        now = end
    }

    var onFound: ((Found) -> Unit)? = null
    var started = 0
    var stopped = 0
    val source = object : DiscoverySource {
        override fun start(onFound: (Found) -> Unit) { started++; this@Fixture.onFound = onFound }
        override fun stop() { stopped++; onFound = null }
    }
    val probed = ArrayList<Triple<String, Int, String>>()
    val results = HashMap<String, ProbeResult>()
    val probe = Probe { h, p, c -> probed.add(Triple(h, p, c)); results[h] ?: ProbeResult.UNREACHABLE }
    val addresses = ArrayList<Pair<String, Int>>()
    val states = ArrayList<DiscoveryState>()
    val finder = AddressFinder(source, probe, { pairing }, { allowed }, { h, p -> addresses.add(h to p) }, { states.add(it) }, scheduler) { it() }
    fun see(f: Found) = onFound?.invoke(f)
}

class AddressFinderTest {
    @Test fun theMatchingComputerThatPassesThePinIsHandedBackAndTheSearchStops() {
        val f = Fixture()
        f.results["10.154.121.113"] = ProbeResult.MATCH
        f.finder.request()
        assertEquals(DiscoveryState.LOOKING, f.finder.current)
        f.see(found("10.154.121.113"))
        assertEquals(listOf("10.154.121.113" to 47821), f.addresses)
        assertEquals(DiscoveryState.IDLE, f.finder.current)
        assertEquals(1, f.stopped)
    }

    @Test fun aLookalikeWithTheSameIdButAnotherCertificateIsDroppedAndNeverSaved() {
        val f = Fixture()
        f.results["192.168.1.99"] = ProbeResult.PIN_MISMATCH // same id announced, different certificate
        f.finder.request()
        f.see(found("192.168.1.99"))
        f.see(found("192.168.1.99")) // announced again: not tried again
        assertTrue("nothing is saved", f.addresses.isEmpty())
        assertEquals("tried once only", 1, f.probed.size)
        assertEquals(DiscoveryState.LOOKING, f.finder.current)
    }

    @Test fun theCheckIsGivenTheFullPinnedCertificateAndNoTokenCanBeInIt() {
        val f = Fixture()
        f.results["10.0.0.7"] = ProbeResult.MATCH
        f.finder.request()
        f.see(found("10.0.0.7"))
        val (host, port, cert) = f.probed.single()
        assertEquals("10.0.0.7", host); assertEquals(47821, port); assertEquals(CERT, cert)
        // by construction: the probe's parameters are host, port and the certificate, never the token
        assertFalse(listOf(host, port.toString(), cert).any { TOKEN in it })
    }

    @Test fun whenTheSameFingerprintAppearsTwiceTheFirstOneThatPassesWins() {
        val f = Fixture()
        f.results["192.168.1.5"] = ProbeResult.PIN_MISMATCH
        f.results["192.168.1.6"] = ProbeResult.MATCH
        f.results["192.168.1.7"] = ProbeResult.MATCH
        f.finder.request()
        f.see(found("192.168.1.5")); f.see(found("192.168.1.6")); f.see(found("192.168.1.7"))
        assertEquals(listOf("192.168.1.6" to 47821), f.addresses)
    }

    @Test fun aComputerThatMatchesNoFingerprintIsNeverProbed() {
        val f = Fixture()
        f.finder.request()
        f.see(found("192.168.1.5", id = "1111111111111111"))
        f.see(found("192.168.1.6", id = null))
        assertTrue(f.probed.isEmpty() && f.addresses.isEmpty())
    }

    @Test fun anUnreachableAnnouncementMayBeTriedAgainWhenItIsAnnouncedAgain() {
        val f = Fixture()
        f.finder.request()
        f.see(found("192.168.1.5"))
        f.results["192.168.1.5"] = ProbeResult.MATCH
        f.see(found("192.168.1.5"))
        assertEquals(2, f.probed.size)
        assertEquals(1, f.addresses.size)
    }

    @Test fun nothingFoundInFifteenSecondsIsNotFoundAndTheNextSearchWaits() {
        val f = Fixture()
        f.finder.request()
        f.advance(14_999)
        assertEquals(DiscoveryState.LOOKING, f.finder.current)
        f.advance(1)
        assertEquals(DiscoveryState.NOT_FOUND, f.finder.current)
        assertEquals(1, f.started)
        assertEquals("the source is stopped between searches", 1, f.stopped)
        f.advance(19_999)
        assertEquals("still waiting (20 s)", 1, f.started)
        f.advance(1)
        assertEquals(2, f.started)
        assertEquals(DiscoveryState.LOOKING, f.finder.current)
    }

    @Test fun theWaitsBetweenSearchesGrowAndNothingScansAroundTheClock() {
        val f = Fixture()
        f.finder.request()
        var searches = 0
        var lastStart = f.started
        val starts = ArrayList<Long>()
        repeat(40) {
            f.advance(10_000)
            if (f.started != lastStart) { starts.add(f.now); lastStart = f.started; searches++ }
        }
        // 400 s of simulated time: well under one search per 15 s window
        assertTrue("searches in 400 s: $searches", searches <= 6)
        val gaps = starts.zipWithNext { a, b -> b - a }
        assertEquals(gaps.sorted(), gaps)
    }

    @Test fun aNetworkChangeSearchesAtOnceAndResetsTheWaiting() {
        val f = Fixture()
        f.finder.request(); f.advance(15_000) // not found, waiting 20 s
        assertEquals(DiscoveryState.NOT_FOUND, f.finder.current)
        f.finder.networkChanged()
        assertEquals(DiscoveryState.LOOKING, f.finder.current)
        assertEquals(2, f.started)
    }

    @Test fun requestingWhileSearchingOrWaitingDoesNotStartASecondSearch() {
        val f = Fixture()
        f.finder.request(); f.finder.request()
        assertEquals(1, f.started)
        f.advance(15_000)
        f.finder.request() // waiting for the next one
        assertEquals(1, f.started)
    }

    @Test fun whenTheLinkIsUpEverythingStopsAndNothingIsScheduled() {
        val f = Fixture()
        f.finder.request(); f.advance(15_000)
        f.finder.connected()
        assertEquals(DiscoveryState.IDLE, f.finder.current)
        f.advance(600_000)
        assertEquals("no search ever started again", 1, f.started)
    }

    @Test fun noPairingOrNotAllowedMeansNoSearch() {
        val none = Fixture(pairing = null)
        none.finder.request()
        assertEquals(0, none.started)
        val off = Fixture(allowed = false)
        off.finder.request()
        assertEquals(0, off.started)
        assertEquals(DiscoveryState.IDLE, off.finder.current)
    }

    @Test fun aResultThatArrivesAfterTheSearchEndedIsIgnored() {
        val f = Fixture()
        f.finder.request()
        val late = f.onFound!!
        f.advance(15_000)
        f.results["10.0.0.7"] = ProbeResult.MATCH
        late(found("10.0.0.7"))
        assertTrue(f.addresses.isEmpty())
    }

    @Test fun theUserSeesLookingThenFoundAsStates() {
        val f = Fixture()
        f.results["10.0.0.7"] = ProbeResult.MATCH
        f.finder.request()
        f.see(found("10.0.0.7"))
        assertEquals(listOf(DiscoveryState.LOOKING, DiscoveryState.IDLE), f.states)
    }
}
