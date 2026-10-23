package com.coucou.android.core

/**
 * Decides when the ongoing notification is posted again. Every push to the surfaces comes here, but the notification shows only a
 * title, a detail, one line per agent, its accent colour and (on a locked screen) whether the link is up: a push that changes none of
 * those is dropped, so the shade is not redrawn for nothing. Pure, so the rule is a unit test.
 */
class OngoingGate {
    /** What the notification would show. */
    data class Key(val title: String, val detail: String, val lines: List<String>, val argb: Int, val connected: Boolean)

    private var last: Key? = null

    /** The key for a glance (null: nothing known yet, the notification says "connecting"). */
    fun keyOf(g: Glance?): Key =
        if (g == null) Key("", "", emptyList(), GlanceTone.CALM.argb, false)
        else Key(g.headline, g.detail, g.lines.map { "${it.agent}: ${it.text}" }, g.tone.argb, g.connected)

    /** True the first time and whenever the notification would look different; false for a push that changes nothing. */
    @Synchronized
    fun shouldPost(g: Glance?): Boolean {
        val k = keyOf(g)
        if (k == last) return false
        last = k
        return true
    }

    /** The notification was removed or rebuilt elsewhere (the service started again): the next push posts. */
    @Synchronized
    fun forget() { last = null }
}
