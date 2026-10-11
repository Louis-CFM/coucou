package com.coucou.android

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Guards for the Android side of "finding the computer again" (system pieces cannot run in a JVM test, so these read the sources). */
class DiscoverySourceTest {
    private fun src(name: String) = File("src/main/kotlin/com/coucou/android/$name").readText()
    private val nsd get() = src("app/NsdDiscovery.kt")
    private val model get() = src("app/AppModel.kt")
    private val discovery get() = src("link/Discovery.kt")

    @Test fun itUsesTheFrameworkAndNoNewLibrary() {
        assertTrue(nsd.contains("NsdManager") && nsd.contains("Discovery.SERVICE_TYPE"))
        val gradle = File("build.gradle.kts").readText().lowercase()
        for (bad in listOf("jmdns", "zeroconf", "play-services", "mlkit", "androidx.nsd")) assertFalse("build.gradle.kts mentions $bad", gradle.contains(bad))
        assertEquals("_coucou._tcp", Regex("""SERVICE_TYPE\s*=\s*"([^"]+)"""").find(discovery)!!.groupValues[1])
    }

    @Test fun theMulticastLockIsHeldOnlyWhileBrowsing() {
        val start = nsd.substringAfter("override fun start").substringBefore("override fun stop")
        val stop = nsd.substringAfter("override fun stop").substringBefore("private fun enqueue")
        assertTrue(start.contains("acquire()"))
        assertTrue(stop.contains("release()"))
        assertTrue(File("src/main/AndroidManifest.xml").readText().contains("CHANGE_WIFI_MULTICAST_STATE"))
    }

    @Test fun theMatchingChecksAndTheSecretNeverMeet() {
        // the probe has no token parameter, and neither the browsing code nor the finder ever mentions one
        assertTrue(Regex("""fun interface Probe\s*\{\s*fun check\(host: String, port: Int, certSha256: String\): ProbeResult\s*\}""").containsMatchIn(discovery))
        assertFalse(nsd.contains("token", ignoreCase = true))
        assertFalse(discovery.substringBefore("object PinnedProbe").contains(".token") && discovery.contains("Log."))
        assertFalse("the token is never logged", Regex("""Log\.[a-z]\([^)]*token""", RegexOption.IGNORE_CASE).containsMatchIn(model + nsd + discovery))
    }

    @Test fun theSavedAddressIsTriedFirstAndTheNetworkIsOnlySearchedAfterAFailure() {
        assertTrue(model.contains("override fun onConnectFailed(consecutive: Int)"))
        assertTrue(model.contains("DiscoveryPolicy.FAILURES_BEFORE_DISCOVERY"))
        assertTrue(src("link/LinkClient.kt").contains("DiscoveryPolicy.SAVED_CONNECT_TIMEOUT_MS"))
    }

    @Test fun nothingScansWithoutAPairingOrWithoutWifiAndTheSearchEndsWithTheLink() {
        val stopLink = model.substringAfter("private fun stopLink()").substringBefore("}\n")
        assertTrue(stopLink.contains("finder.stop()") && stopLink.contains("netWatch.stop()"))
        assertTrue(model.contains("if (!wifiUp) { finder.stop(); return }"))
        assertTrue(model.contains("if (state == LinkState.CONNECTED) finder.connected()"))
        assertTrue(model.contains("DiscoveryPolicy.mayDiscover("))
    }

    @Test fun aFoundAddressChangesOnlyTheAddressInTheStoredPairing() {
        val use = model.substringAfter("private fun useAddress").substringBefore("/** A computer matching")
        assertTrue(use.contains("Discovery.withAddress(p, host, port)") && use.contains("store.savePairing(q)"))
        assertTrue("a manual address goes through the same function", model.substringAfter("fun setAddress").substringBefore("/**").contains("useAddress(host, port)"))
    }

    @Test fun theNetworkCallbackIsRegisteredOnlyWhilePairedAndNeverPolls() {
        val watch = src("app/NetworkWatch.kt")
        assertTrue(watch.contains("registerDefaultNetworkCallback") && watch.contains("unregisterNetworkCallback"))
        assertFalse(watch.contains("Thread.sleep") || watch.contains("postDelayed"))
        assertTrue(model.substringAfter("private fun connect(").substringBefore("/** The saved address").contains("netWatch.start()"))
    }

    @Test fun theStatusLineAndTheHintSayWhatIsHappening() {
        assertTrue(src("ui/LinkStatus.kt").contains("R.string.status_looking"))
        val hint = src("ui/DiscoveryHint.kt")
        for (s in listOf("discovery_title", "discovery_body", "discovery_pair_again", "discovery_enter_address", "address_save")) assertTrue(s, hint.contains("R.string.$s"))
        assertTrue(src("MainActivity.kt").contains("model.discovery == DiscoveryState.NOT_FOUND"))
        val strings = File("src/main/res/values/strings.xml").readText()
        assertTrue(strings.contains("same Wi-Fi") && strings.contains("client isolation") && strings.contains("private networks"))
    }

}
