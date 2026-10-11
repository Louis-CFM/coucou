package com.coucou.android.core

import com.coucou.android.link.DiffRow
import com.coucou.android.link.Protocol
import com.coucou.android.link.ServerMsg

/** A file's change, whole: what the sheet shows. Held in memory only while the sheet is open. */
data class FileDiffView(
    val pillId: String, val fileId: Long, val name: String, val added: Int, val removed: Int,
    val tooLarge: Boolean, val gone: Boolean, val truncated: Boolean, val rows: List<DiffRow>,
)

/** What the sheet is doing. */
sealed interface DiffState {
    data object Idle : DiffState
    data class Loading(val pillId: String, val fileId: Long, val name: String) : DiffState
    data class Ready(val diff: FileDiffView) : DiffState
    /** The computer did not answer in time, or the link is down. */
    data class Failed(val name: String) : DiffState
}

/**
 * Puts the parts of a diff back together. Only the diff that was asked for is kept; a part that is not
 * the next one, from another file, or beyond the computer's limits, is dropped. Never stored.
 */
class DiffAssembler {
    private var pillId: String? = null
    private var fileId: Long = -1
    private var parts = 0
    private val received = ArrayList<ServerMsg.Diff>()

    /** The diff being waited for; anything else that arrives is dropped. */
    fun expect(pillId: String, fileId: Long) {
        this.pillId = pillId
        this.fileId = fileId
        parts = 0
        received.clear()
    }

    fun cancel() { pillId = null; received.clear(); parts = 0 }

    /** The whole diff once its last part is in, else null. */
    fun accept(m: ServerMsg.Diff): FileDiffView? {
        if (m.pillId != pillId || m.fileId != fileId) return null
        if (m.part == 0) {
            received.clear()
            parts = m.parts
        } else if (m.parts != parts || m.part != received.size) {
            return null // out of order or from another answer: wait for a fresh first part
        }
        received.add(m)
        if (received.size < parts) return null
        val rows = received.flatMap { it.lines }.take(Protocol.MAX_DIFF_LINES)
        val first = received.first()
        val view = FileDiffView(
            m.pillId, m.fileId, first.name, first.added, first.removed, first.tooLarge, first.gone,
            first.truncated || received.sumOf { it.lines.size } > Protocol.MAX_DIFF_LINES, rows,
        )
        cancel()
        return view
    }
}
