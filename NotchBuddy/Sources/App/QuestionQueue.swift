import Foundation

// MARK: - QuestionQueue
// Pure FIFO queue of pending AskUserQuestions, one per session. No AppKit, no SwiftUI, no I/O:
// HookServer owns the sockets, timers and UI, and mutates this value on the main actor only.
// The head is the question shown on the card; every question keeps its own connection, so an
// answer always goes back to the session that asked.

struct QueuedQuestion: Equatable, Sendable {
    let id: UUID
    /// Client socket, held open until the user answers. Closed by the owner's dispatch source.
    let fd: Int32
    /// The session's id, or "<pill>+<cwd>" for a session that sends none.
    let sessionId: String
    /// "integration_claude", "agent_cursor" or "agent_codex".
    let pillId: String
    let projectName: String
    let cwd: String
    let question: AskQuestion
    /// Which iPhone record carries the question: 1 is the pill's own, 2, 3… one of its own
    /// (see `phoneRecordId`). Given by the queue, kept for the question's whole life.
    var slot: Int = 1
    /// When the question arrived (answers sent before it are not for it).
    var received = Date()
    /// The pill the question shows on when its session popped out of `pillId` (SessionBoard),
    /// nil when it shows on `pillId` itself.
    var shownPill: String? = nil

    /// Where the card and the focus find the question.
    var displayPill: String { shownPill ?? pillId }

    /// The iPhone record that shows this question: the popped-out pill's own when its session
    /// popped out, else the pill's own for the first question behind a pill, "<pill>#q<slot>"
    /// for the others, so each session's question is answered on its own (a popped-out pill is
    /// "<pill>#<n>": the two never meet). The iPhone sends this id back with its answer.
    var phoneRecordId: String { shownPill ?? (slot == 1 ? pillId : "\(pillId)#q\(slot)") }
}

struct QuestionQueue: Sendable {
    /// Upper bound of simultaneously pending questions. Each one holds a socket and a 120 s
    /// timer; beyond this the newest goes back to its terminal.
    static let maxPending = 5

    enum EnqueueResult: Equatable, Sendable {
        /// Queued. `replaced` is the same session's earlier question, now taken out of the
        /// queue: the caller hands it back to its terminal.
        case accepted(replaced: QueuedQuestion?)
        case rejectedFull
    }

    private(set) var entries: [QueuedQuestion] = []

    var head: QueuedQuestion? { entries.first }
    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }

    func contains(id: UUID) -> Bool { entries.contains { $0.id == id } }

    func entry(id: UUID) -> QueuedQuestion? { entries.first { $0.id == id } }

    func hasEntries(forPill pillId: String) -> Bool {
        entries.contains { $0.pillId == pillId }
    }

    /// Queues `entry` behind the others and gives it the lowest record slot free on its pill.
    /// A session waits on one question at a time: a newer one from the same session takes
    /// the older one's place and slot, and the older is returned so its connection can be answered.
    mutating func enqueue(_ entry: QueuedQuestion, maxPending: Int = QuestionQueue.maxPending) -> EnqueueResult {
        var entry = entry
        if let idx = entries.firstIndex(where: { $0.sessionId == entry.sessionId && $0.pillId == entry.pillId }) {
            let replaced = entries[idx]
            entry.slot = replaced.slot
            entries[idx] = entry
            return .accepted(replaced: replaced)
        }
        guard entries.count < maxPending else { return .rejectedFull }
        // A popped-out question has its pill's record: the slots count the others only.
        let taken = Set(entries.filter { $0.pillId == entry.pillId && $0.shownPill == nil }.map(\.slot))
        entry.slot = (1...).first { !taken.contains($0) }!
        entries.append(entry)
        return .accepted(replaced: nil)
    }

    /// Removes only the entry with this id. Other entries keep their order and slots.
    @discardableResult
    mutating func remove(id: UUID) -> QueuedQuestion? {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return nil }
        return entries.remove(at: idx)
    }

    /// Empties the queue, oldest first.
    mutating func removeAll() -> [QueuedQuestion] {
        defer { entries = [] }
        return entries
    }

    /// The waiting question an iPhone answer is for: the same question (`fingerprint`, as
    /// `fingerprintOf` computes it) on the record the answer names. An answer that names no
    /// record goes to the oldest such question. nil when none waits any more.
    static func question(answering fingerprint: String, onRecord recordId: String,
                         in entries: [QueuedQuestion],
                         fingerprintOf: (AskQuestion) -> String) -> QueuedQuestion? {
        let same = entries.filter { fingerprintOf($0.question) == fingerprint }
        if recordId.isEmpty { return same.first }
        return same.first { $0.phoneRecordId == recordId }
    }
}
