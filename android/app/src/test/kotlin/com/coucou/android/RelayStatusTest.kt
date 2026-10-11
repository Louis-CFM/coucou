package com.coucou.android

import com.coucou.android.core.RelayLineKind
import com.coucou.android.core.RelayStatus
import com.coucou.android.link.RelayIssue
import com.coucou.android.link.Route
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RelayStatusTest {
    private fun kind(hasRelay: Boolean = true, use: Boolean = true, connected: Boolean = false, route: Route? = null, issue: RelayIssue = RelayIssue.NONE) =
        RelayStatus.kind(hasRelay, use, connected, route, issue)

    @Test fun aPairingWithoutARelayExplainsHowToGetOne() = assertEquals(RelayLineKind.NO_RELAY_IN_PAIRING, kind(hasRelay = false, connected = true))

    @Test fun switchedOffSaysSo() = assertEquals(RelayLineKind.SWITCHED_OFF, kind(use = false, connected = true, route = Route.LAN))

    @Test fun connectedSaysWhichWay() {
        assertEquals(RelayLineKind.DIRECT, kind(connected = true, route = Route.LAN))
        assertEquals(RelayLineKind.VIA_RELAY, kind(connected = true, route = Route.RELAY))
    }

    @Test fun notConnectedNamesTheReason() {
        assertEquals(RelayLineKind.WAITING, kind())
        assertEquals(RelayLineKind.ACCESS_REFUSED, kind(issue = RelayIssue.ACCESS_REFUSED))
        assertEquals(RelayLineKind.ROOM_TAKEN, kind(issue = RelayIssue.ROOM_TAKEN))
        assertEquals(RelayLineKind.RATE_LIMITED, kind(issue = RelayIssue.RATE_LIMITED))
        assertEquals(RelayLineKind.UNREACHABLE, kind(issue = RelayIssue.UNREACHABLE))
        assertEquals(RelayLineKind.COMPUTER_AWAY, kind(issue = RelayIssue.COMPUTER_AWAY))
    }

    @Test fun everyRelayIssueHasItsOwnSentence() {
        val kinds = RelayIssue.values().map { kind(issue = it) }
        assertEquals(kinds.size, kinds.toSet().size)
        assertTrue(kinds.none { it == RelayLineKind.DIRECT || it == RelayLineKind.VIA_RELAY })
    }
}
