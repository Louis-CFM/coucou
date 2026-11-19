package com.coucou.android.core

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * Collision-free notification tags, fixed notification IDs, and PendingIntent request codes.
 * Using unique `(tag, fixedId)` pairs instead of `hashCode()` avoids independent approvals or
 * sessions overwriting each other when 30-bit string hashes collide.
 */
object NotificationIds {
    const val ONGOING_ID = 1
    const val STATUS_ID = 2
    const val APPROVAL_ID = 3
    private const val STATUS_TAG_PREFIX = "status:"
    private const val APPROVAL_TAG_PREFIX = "approval:"

    private val nextCode = AtomicInteger(10)
    private val requestCodes = ConcurrentHashMap<String, Int>()

    fun statusTag(pillId: String): String = "$STATUS_TAG_PREFIX$pillId"

    fun isStatusTag(tag: String?): Boolean = tag != null && (tag == "status" || tag.startsWith(STATUS_TAG_PREFIX))

    fun approvalTag(fingerprint: String): String = "$APPROVAL_TAG_PREFIX$fingerprint"

    fun requestCode(key: String): Int = requestCodes.computeIfAbsent(key) {
        nextCode.getAndUpdate { cur -> if (cur == Int.MAX_VALUE) 10 else cur + 1 }
    }
}
