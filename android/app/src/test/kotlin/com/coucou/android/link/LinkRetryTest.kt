package com.coucou.android.link

import java.io.IOException
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The reconnect loop's two additions for finding the computer again: it reports failures, and a retry can cut the wait short. */
class LinkRetryTest {
    private val pairing = PairingPayload("192.168.10.6", 47821, "ab".repeat(32), "T".repeat(20), "PC")

    private class Listener : LinkListener {
        val failures = CopyOnWriteArrayList<Int>()
        val tick = CountDownLatch(3)
        override fun onConnectFailed(consecutive: Int) { failures.add(consecutive); tick.countDown() }
    }

    @Test fun everyFailedAttemptIsReportedWithARunningCount() {
        val l = Listener()
        val attempts = CopyOnWriteArrayList<Int>()
        val c = LinkClient(
            pairing, "test", l, connector = { timeout -> attempts.add(timeout); throw IOException("no route") },
            backoffMs = longArrayOf(5), caps = emptyList(),
        )
        c.start()
        assertTrue(l.tick.await(5, TimeUnit.SECONDS))
        c.stop()
        assertEquals(listOf(1, 2, 3), l.failures.take(3))
        assertTrue("the saved address gets the short timeout", attempts.all { it == DiscoveryPolicy.SAVED_CONNECT_TIMEOUT_MS })
    }

    @Test fun retryNowCutsALongBackoffShort() {
        val l = object : LinkListener {
            val second = CountDownLatch(2)
            override fun onConnectFailed(consecutive: Int) { second.countDown() }
        }
        val c = LinkClient(pairing, "test", l, connector = { throw IOException("no route") }, backoffMs = longArrayOf(60_000), caps = emptyList())
        c.start()
        Thread.sleep(300) // first attempt failed, now waiting a minute
        assertEquals(1L, l.second.count)
        c.retryNow()
        assertTrue("the second attempt follows at once", l.second.await(3, TimeUnit.SECONDS))
        c.stop()
    }

    @Test fun stoppingEndsTheWaitToo() {
        val c = LinkClient(pairing, "test", object : LinkListener {}, connector = { throw IOException("x") }, backoffMs = longArrayOf(60_000), caps = emptyList())
        c.start()
        Thread.sleep(200)
        val t0 = System.nanoTime()
        c.stop()
        assertTrue(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - t0) < 1_000)
    }
}
