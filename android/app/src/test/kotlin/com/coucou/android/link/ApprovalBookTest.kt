package com.coucou.android.link

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class ApprovalBookTest {
    private var now = 1_000_000L
    private val book = ApprovalBook { now }
    private fun req(fp: String, created: Long = now) = ApprovalRequest("p", fp, "Bash", "ls", created)

    @Test fun claimedRequestCanOnlyBeDecidedOnce() {
        book.add(req("a"))
        assertNotNull(book.claim("a"))
        assertNull(book.claim("a"))
    }

    @Test fun unknownRequestCannotBeDecided() {
        assertNull(book.claim("never-seen"))
    }

    @Test fun expiresAfterTheTtl() {
        book.add(req("a"))
        now += Protocol.APPROVAL_TTL_MS - 1
        assertEquals(1, book.active().size)
        now += 1
        assertEquals(0, book.active().size)
    }

    @Test fun theDesktopsClockDoesNotDecideWhetherARequestIsExpired() {
        // A computer whose clock is 10 minutes behind (or ahead) of the phone's.
        book.add(req("slow", created = now - 600_000))
        book.add(req("fast", created = now + 600_000))
        assertNotNull("a fresh request must be decidable", book.claim("slow"))
        assertNotNull("a fresh request must be decidable", book.claim("fast"))
    }

    @Test fun aRequestSentAgainKeepsItsFirstArrivalTime() {
        book.add(req("a"))
        now += Protocol.APPROVAL_TTL_MS - 1_000
        book.add(req("a")) // the link dropped and came back: the desktop offers it again
        now += 1_000
        assertNull("it must not live longer for having been sent twice", book.claim("a"))
    }

    @Test fun resolvedByTheDesktopDisappears() {
        book.add(req("a"))
        book.resolve("a")
        assertNull(book.claim("a"))
    }

    @Test fun keepsArrivalOrder() {
        book.add(req("a")); book.add(req("b")); book.add(req("c"))
        assertEquals(listOf("a", "b", "c"), book.active().map { it.fingerprint })
    }
}
