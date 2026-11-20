package com.coucou.android

import com.coucou.android.core.NotificationIds
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationIdsTest {
    @Test fun distinctIdsNeverCollideEvenWhenHashCodesMatch() {
        // "Aa" and "BB" share the exact same Java hashCode() (2112).
        assertEquals("Aa".hashCode(), "BB".hashCode())

        assertNotEquals(NotificationIds.statusTag("Aa"), NotificationIds.statusTag("BB"))
        assertNotEquals(NotificationIds.approvalTag("Aa"), NotificationIds.approvalTag("BB"))
        assertNotEquals(NotificationIds.requestCode("allow:Aa"), NotificationIds.requestCode("allow:BB"))
        assertNotEquals(NotificationIds.requestCode("deny:Aa"), NotificationIds.requestCode("allow:Aa"))
    }

    @Test fun requestCodeIsStableForTheSameKey() {
        val first = NotificationIds.requestCode("open:stable-fp")
        val second = NotificationIds.requestCode("open:stable-fp")
        assertEquals(first, second)
        assertTrue(first >= 10)
    }

    @Test fun statusTagMatcherRecognizesStatusTagsOnly() {
        assertTrue(NotificationIds.isStatusTag("status"))
        assertTrue(NotificationIds.isStatusTag(NotificationIds.statusTag("claude_1")))
        assertFalse(NotificationIds.isStatusTag(NotificationIds.approvalTag("fp1")))
        assertFalse(NotificationIds.isStatusTag(null))
    }

    @Test fun fixedNotificationIdsAreDistinct() {
        val ids = setOf(NotificationIds.ONGOING_ID, NotificationIds.STATUS_ID, NotificationIds.APPROVAL_ID)
        assertEquals(3, ids.size)
    }
}
