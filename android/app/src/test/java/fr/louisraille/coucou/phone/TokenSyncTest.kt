package fr.louisraille.coucou.phone

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TokenSyncTest {
    @Test
    fun aNewOrChangedTokenIsClaimed() {
        assertTrue(TokenSync.shouldClaim(null, "t1"))
        assertTrue(TokenSync.shouldClaim("t0", "t1"))
    }

    @Test
    fun theSameTokenIsNotClaimedTwice() {
        assertFalse(TokenSync.shouldClaim("t1", "t1"))
    }

    @Test
    fun noTokenIsNothingToClaim() {
        assertFalse(TokenSync.shouldClaim("t1", null))
        assertFalse(TokenSync.shouldClaim(null, ""))
    }

    @Test
    fun deviceIdsAre32LowercaseHexAndDiffer() {
        val a = DeviceId.new()
        val b = DeviceId.new()
        assertTrue(a, a.matches(Regex("[0-9a-f]{32}")))
        assertNotEquals(a, b)
    }
}
