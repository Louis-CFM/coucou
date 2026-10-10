import Foundation

/// The edit being followed live (Settings → Follow edits live).
struct LiveDiff: Equatable {
    let pillId: String
    let diffId: Int
}

enum LiveEdits {
    /// Whether a new file edit may take the island over to show its diff: never over
    /// a waiting card, another open view, typing, or another session's live diff, nor
    /// for a session whose live diff was closed until its next prompt.
    static func mayFollow(enabled: Bool, stopped: Bool, cardPending: Bool, expanded: Bool,
                          onOverview: Bool, typing: Bool, followingOther: Bool) -> Bool {
        guard enabled, !stopped, !cardPending else { return false }
        guard expanded else { return true }
        return onOverview && !typing && !followingOther
    }
}
