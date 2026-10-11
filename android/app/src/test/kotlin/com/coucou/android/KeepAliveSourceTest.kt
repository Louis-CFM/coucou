package com.coucou.android

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** How the link is kept alive while the phone sleeps, checked where a unit test can see it: the wiring and the permissions. */
class KeepAliveSourceTest {
    private fun src(path: String) = File("src/main/kotlin/com/coucou/android/$path").readText()
    private val manifest get() = File("src/main/AndroidManifest.xml").readText()

    @Test fun theAlarmUsesAllowWhileIdleAndNoExactAlarmPermission() {
        val alarm = src("app/KeepAlive.kt")
        assertTrue(alarm.contains("setAndAllowWhileIdle"))
        assertFalse("no exact alarms: they need a permission Google restricts", alarm.contains("setExact") || manifest.contains("SCHEDULE_EXACT_ALARM") || manifest.contains("USE_EXACT_ALARM"))
        assertTrue(alarm.contains("AlarmManager.ELAPSED_REALTIME_WAKEUP"))
    }

    @Test fun theWakeLocksHaveATimeoutAndAreTakenInTwoPlacesOnly() {
        val all = File("src/main/kotlin").walkTopDown().filter { it.extension == "kt" }.joinToString("\n") { it.readText() }
        assertEquals("two wake locks in the whole app: the keep-alive check and the screen light for an approval", 2, Regex("""newWakeLock\(""").findAll(all).count())
        assertTrue(src("app/KeepAlive.kt").contains("acquire(KeepAlivePolicy.WAKE_LOCK_MS)"))
        assertTrue("the approval screen light is short and only when the screen is off", src("app/Notifications.kt").contains("acquire(WAKE_MS)") && src("app/Notifications.kt").contains("WAKE_MS = 6_000L"))
        assertFalse("never held without a timeout", Regex("""wakeLock\w*\.acquire\(\)""", RegexOption.IGNORE_CASE).containsMatchIn(all))
        assertTrue(manifest.contains("android.permission.WAKE_LOCK"))
    }

    @Test fun theReceiverIsNotExportedSoOnlyOurAlarmCanStartIt() {
        assertTrue(Regex("""<receiver\s+android:name="\.app\.KeepAliveReceiver"\s+android:exported="false"\s*/>""").containsMatchIn(manifest))
    }

    @Test fun theAlarmAndTheWatchersLiveExactlyAsLongAsThePairing() {
        val model = src("app/AppModel.kt")
        val connect = model.substringAfter("private fun connect(p: PairingPayload)").substringBefore("/** The saved address")
        assertTrue(connect.contains("screenWatch.start()") && connect.contains("KeepAliveAlarm.arm(context)"))
        val stop = model.substringAfter("private fun stopLink()").substringBefore("notifier.cancelAllStatus()")
        assertTrue(stop.contains("screenWatch.stop()") && stop.contains("KeepAliveAlarm.cancel(context)"))
        // The alarm chain ends by itself when there is no pairing any more.
        assertTrue(model.substringAfter("fun keepAliveTick()").substringBefore("}").contains("if (mode != Mode.PAIRED) return"))
    }

    @Test fun everyWakeUpGoesThroughThePolicy() {
        val model = src("app/AppModel.kt")
        assertTrue(model.contains("ReconnectPolicy.decide("))
        assertTrue(model.contains("onWake(Wake.NEW_NETWORK)") && model.contains("onWake(Wake.SCREEN_ON)") && model.contains("onWake(Wake.ALARM)"))
        assertTrue("a network that appears is looked at, not only Wi-Fi", src("app/NetworkWatch.kt").contains("onAvailable(network: Network) { changed(); onNewNetwork() }"))
    }

    @Test fun theLinkAsksForAPongAtEveryCheckAndKeepsTheSystemsOwnProbeToo() {
        val client = src("link/LinkClient.kt")
        assertTrue(client.contains("override fun checkNow()"))
        assertTrue(client.contains("s.keepAlive = true"))
    }

    @Test fun theBatterySettingIsOnlyEverOpenedNeverChangedByTheApp() {
        val ui = src("ui/ConnectionHelp.kt")
        assertTrue(ui.contains("ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS") && ui.contains("ACTION_APPLICATION_DETAILS_SETTINGS"))
        assertFalse("the direct request needs a permission Google restricts", manifest.contains("REQUEST_IGNORE_BATTERY_OPTIMIZATIONS") || ui.contains("ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"))
    }

    @Test fun cantConnectIsInTheComputerPanelOnlyWhenPaired() {
        val settings = src("ui/SettingsScreens.kt")
        val paired = settings.substringAfter("Mode.PAIRED -> {").substringBefore("Mode.DEMO ->")
        assertTrue(paired.contains("LinkRow(stringResource(R.string.diag_title), onDiagnostics)"))
        assertFalse(settings.substringAfter("Mode.DEMO ->").substringBefore("Mode.NONE").contains("diag_title"))
    }

    @Test fun theDiagnosticsScreenIsNotSecretButTheReportMasksTheAddress() {
        assertTrue(src("app/AppModel.kt").contains("Diagnostics.maskHost(it.host)"))
        assertFalse(src("ui/DiagnosticsScreen.kt").contains("p.token") || src("ui/DiagnosticsScreen.kt").contains("certSha256"))
    }
}
