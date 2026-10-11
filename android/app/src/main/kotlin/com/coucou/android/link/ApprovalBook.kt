package com.coucou.android.link

/**
 * Pending approvals as the phone sees them. A decision can only be sent for a request that is
 * still pending and younger than [Protocol.APPROVAL_TTL_MS]; each request is decided once.
 *
 * The age is counted from the moment the request ARRIVED, on this phone's own clock. The
 * desktop's `createdAt` is not used for it: a computer whose clock is a few minutes off would
 * otherwise make every request look expired (or immortal) on the phone.
 */
class ApprovalBook(private val clockMs: () -> Long) {
    private class Entry(val request: ApprovalRequest, val arrivedMs: Long)

    private val pending = LinkedHashMap<String, Entry>()

    @Synchronized fun add(r: ApprovalRequest) {
        // The same request sent again (a reconnect) keeps its first arrival time.
        pending.getOrPut(r.fingerprint) { Entry(r, clockMs()) }
    }

    @Synchronized fun resolve(fingerprint: String): ApprovalRequest? = pending.remove(fingerprint)?.request

    /** Still-valid requests, oldest first. Expired ones are dropped as a side effect. */
    @Synchronized fun active(): List<ApprovalRequest> {
        val now = clockMs()
        pending.values.removeAll { now - it.arrivedMs >= Protocol.APPROVAL_TTL_MS }
        return pending.values.map { it.request }
    }

    /** Takes the request out for deciding; null if unknown, already decided or expired. */
    @Synchronized fun claim(fingerprint: String): ApprovalRequest? {
        active()
        return pending.remove(fingerprint)?.request
    }

    /** Puts a claimed request back (the decision could not be sent) with its remaining time. */
    @Synchronized fun restore(r: ApprovalRequest, arrivedMs: Long) { pending[r.fingerprint] = Entry(r, arrivedMs) }

    /** How long ago it arrived, or null if it is not pending. */
    @Synchronized fun ageMs(fingerprint: String): Long? = pending[fingerprint]?.let { clockMs() - it.arrivedMs }

    @Synchronized fun clear() = pending.clear()
}
