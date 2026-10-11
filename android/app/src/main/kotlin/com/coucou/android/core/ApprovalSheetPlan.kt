package com.coucou.android.core

import com.coucou.android.link.ApprovalRequest

/**
 * What the approval sheet shows and when. Pure, so each rule is a unit test.
 * The sheet rises over any screen while a request waits, until the user closes it; it comes back for
 * the next request, or from the "Review request" button on Home.
 */
object ApprovalSheetPlan {
    /** Taps in the first moments are ignored: the sheet must not catch a tap meant for what was under it. Same as the island's. */
    const val GUARD_MS = 600L

    /** The command box scrolls past this height instead of cutting the text: the whole command that was sent is always readable. */
    const val COMMAND_BOX_MAX_DP = 220

    /**
     * Allow from the phone is offered only when the whole command is on the phone. When the computer cut it (a flag it sends with the
     * request), the phone could show only the start of what would run, so the request is answered on the computer. Deny is always offered.
     */
    fun canAllowHere(r: ApprovalRequest): Boolean = !r.truncated

    /** The request to show: the first one the user has not closed, or null. */
    fun next(approvals: List<ApprovalRequest>, closed: String?): ApprovalRequest? =
        approvals.firstOrNull { it.fingerprint != closed }

    /** "Wants to run a command": what kind of action it is, never the command itself. */
    fun action(tool: String): String = ToolLabels.action(tool)
}
