import Foundation

/// A short moment during which a card that took the place of another card ignores clicks, so a click aimed
/// at the previous card cannot approve or answer the new one. Compiled in every build (the cmux queue has its
/// own lock for promoted cards, in CmuxRouting). It only ignores input: it never answers anything by itself.
enum CardInputLock {
    static let delay: TimeInterval = 0.7

    /// True when an approval or a question is on screen. The fd is live for a real card; a demo card has none.
    static func cardVisible(approvalFD: Int32, questionFD: Int32, approvalShown: Bool, questionShown: Bool) -> Bool {
        approvalFD >= 0 || questionFD >= 0 || approvalShown || questionShown
    }

    /// When the lock starts for a card that is being shown. nil on an empty screen: no delay in the normal case.
    static func armedAt(cardWasVisible: Bool, now: TimeInterval) -> TimeInterval? {
        cardWasVisible ? now : nil
    }

    /// When the lock starts as the approval queue puts another request on the card. nil when no card was shown before
    /// (the arrival arms itself) or when it is the same request (only its "n waiting" count refreshes).
    static func headChangeArmedAt(shownId: UUID?, headId: UUID, now: TimeInterval) -> TimeInterval? {
        guard let shownId, shownId != headId else { return nil }
        return now
    }

    /// When the lock starts as one card hands the slot to another, whichever queue they come from (an approval, a question,
    /// the next question). `shown` is the id of the card on screen, `next` the id of the one that takes it. nil when nothing
    /// was shown (the arrival arms itself), when nothing takes the card, or when it is the same card.
    static func handoverArmedAt(shown: UUID?, next: UUID?, now: TimeInterval) -> TimeInterval? {
        guard let shown, let next, shown != next else { return nil }
        return now
    }

    static func isLocked(armedAt: TimeInterval?, now: TimeInterval) -> Bool {
        guard let at = armedAt else { return false }
        return now >= at && now - at < delay
    }

    // MARK: Hermes cards: a monotonic clock

    /// The clock of the Hermes cards: system uptime. It never steps back (the wall clock does, with a time sync or a change
    /// of time zone or date), so the lock cannot be undone by moving it. The hook cards of other agents keep the wall clock.
    static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Same lock for a clock that may still be moved (a test moves one): a reading before the moment the lock was armed
    /// starts the delay again from that reading, so a step back never unlocks and never locks for longer than `delay`.
    static func isLockedKeepingWindow(armedAt: inout TimeInterval?, now: TimeInterval) -> Bool {
        guard let at = armedAt else { return false }
        if now < at { armedAt = now; return true }
        return now - at < delay
    }
}
