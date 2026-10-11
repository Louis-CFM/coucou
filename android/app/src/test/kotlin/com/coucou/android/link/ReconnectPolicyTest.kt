package com.coucou.android.link

import com.coucou.android.link.ReconnectPolicy.Action
import org.junit.Assert.assertEquals
import org.junit.Test

class ReconnectPolicyTest {
    private fun d(e: Wake, paired: Boolean = true, connected: Boolean = false, wifi: Boolean = true, relay: Boolean = false) =
        ReconnectPolicy.decide(e, paired, connected, wifi, relay)

    @Test fun nothingHappensWithoutAPairing() {
        for (e in Wake.values()) assertEquals(Action.NONE, d(e, paired = false))
    }

    @Test fun whenConnectedEveryWakeUpAsksForAPongInsteadOfTrustingTheSocket() {
        for (e in listOf(Wake.SCREEN_ON, Wake.NEW_NETWORK, Wake.ALARM)) assertEquals("$e", Action.CHECK_NOW, d(e, connected = true))
    }

    @Test fun whenNotConnectedThoseWakeUpsReconnectAtOnce() {
        for (e in listOf(Wake.SCREEN_ON, Wake.NEW_NETWORK, Wake.ALARM)) assertEquals("$e", Action.RETRY_NOW, d(e, connected = false))
    }

    @Test fun withoutAUsableNetworkTheNetworkAndAlarmWakeUpsDoNotBurnBatteryButTheScreenStillTries() {
        assertEquals(Action.NONE, d(Wake.NEW_NETWORK, wifi = false))
        assertEquals(Action.NONE, d(Wake.ALARM, wifi = false))
        assertEquals("a relay works over mobile data", Action.RETRY_NOW, d(Wake.NEW_NETWORK, wifi = false, relay = true))
        assertEquals("the user just woke the phone: try", Action.RETRY_NOW, d(Wake.SCREEN_ON, wifi = false))
    }

    @Test fun losingTheNetworkOrTurningTheScreenOffNeedsNothing() {
        for (connected in listOf(true, false)) {
            assertEquals(Action.NONE, d(Wake.NETWORK_LOST, connected = connected))
            assertEquals(Action.NONE, d(Wake.SCREEN_OFF, connected = connected))
        }
    }
}
