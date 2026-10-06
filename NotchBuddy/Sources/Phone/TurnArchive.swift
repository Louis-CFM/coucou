import Foundation

/// The turns this iPhone saw before the latest one (4 per session), and
/// today's tally. Built from the Turn records as they come, kept in a file on
/// this iPhone only.
struct TurnArchive: Codable {
    var past: [String: [TurnSnapshot]] = [:]
    var today = DayTally()

    static let keptPerSession = 4

    /// Today: turns finished, files changed, lines added and removed.
    struct DayTally: Codable, Equatable {
        var day = Calendar.current.startOfDay(for: .now)
        var turns = 0
        var files = 0
        var added = 0
        var removed = 0
        /// "pillId|startedAt" of the turns counted, so none counts twice.
        var counted: [String] = []

        var isEmpty: Bool { turns == 0 }
    }

    /// A new version of a session's latest turn arrived.
    mutating func update(from old: TurnSnapshot?, to new: TurnSnapshot) {
        // A new turn started: the previous one joins the past turns.
        if let old, old.startedAt != new.startedAt, !(old.prompt.isEmpty && old.actions.isEmpty) {
            var list = past[old.pillId] ?? []
            list.removeAll { $0.startedAt == old.startedAt }
            list.insert(old, at: 0)
            past[old.pillId] = Array(list.prefix(Self.keptPerSession))
        }
        count(new)
    }

    /// Adds a finished turn to today's tally, once.
    mutating func count(_ turn: TurnSnapshot) {
        let startOfToday = Calendar.current.startOfDay(for: .now)
        if today.day != startOfToday { today = DayTally(day: startOfToday) }
        guard let ended = turn.endedAt, ended >= startOfToday else { return }
        let key = "\(turn.pillId)|\(turn.startedAt.timeIntervalSince1970)"
        guard !today.counted.contains(key) else { return }
        today.counted.append(key)
        today.turns += 1
        today.files += Set(turn.files.map(\.path)).count
        today.added += turn.files.reduce(0) { $0 + $1.added }
        today.removed += turn.files.reduce(0) { $0 + $1.removed }
    }

    /// Today's tally, or an empty one after midnight.
    var currentTally: DayTally {
        today.day == Calendar.current.startOfDay(for: .now) ? today : DayTally()
    }

    // MARK: File

    private static var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("turn-archive.json")
    }

    static func load() -> TurnArchive {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let archive = try? JSONDecoder().decode(TurnArchive.self, from: data) else { return TurnArchive() }
        return archive
    }

    func save() {
        guard let url = Self.fileURL, let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
