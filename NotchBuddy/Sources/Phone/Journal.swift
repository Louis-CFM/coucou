import Foundation
import Observation

/// One thing that happened, from any source: a decision taken here, an agent's turn, a payment,
/// a deploy, a run, a booking… The History tab, the search and the home's news read these.
struct JournalEntry: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case decision, turn, service }

    /// What a filter in History groups it under.
    enum Theme: String, Codable, CaseIterable, Sendable {
        case needsYou, code, money, deploys, errors

        var title: String {
            switch self {
            case .needsYou: "Your OKs"
            case .code: "Code"
            case .money: "Money"
            case .deploys: "Deploys"
            case .errors: "Errors"
            }
        }
    }

    /// Stable: the same event seen again updates its line instead of adding one.
    var id: String
    var kind: Kind
    var pillId: String
    var title: String
    var detail: String
    var date: Date
    var tone: ServiceTone
    var url: String?
    var themes: [Theme]
}

/// The journal of everything this iPhone saw, kept on the iPhone for 90 days (a file in the
/// app's own folder, never sent anywhere). Filled after each look at iCloud: the Mac publishes
/// each service's latest events and the agents' turns, and the iPhone keeps them as they pass,
/// so the history reaches further back than any one snapshot.
@MainActor
@Observable
final class Journal {
    static let shared = Journal()

    private(set) var entries: [JournalEntry] = []

    private static let keepDays: Double = 90
    private static let maxEntries = 4_000

    private nonisolated static var fileURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("journal.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode([JournalEntry].self, from: data) {
            entries = saved
        }
    }

    /// Takes in what the iPhone knows now; writes the file only when something changed.
    func record(decisions: [DecisionLog], turns: [TurnSnapshot], services: [String: ServiceSnapshot]) {
        var byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var changed = false
        func put(_ entry: JournalEntry) {
            if byID[entry.id] != entry {
                byID[entry.id] = entry
                changed = true
            }
        }

        for log in decisions {
            put(JournalEntry(id: "decision|\(log.id)", kind: .decision, pillId: log.pillId,
                             title: log.decision == .allow ? "Allowed" : "Denied", detail: log.summary,
                             date: log.date, tone: log.decision == .allow ? .ok : .error, url: nil,
                             themes: [.needsYou, .code]))
        }
        for turn in turns where !turn.prompt.isEmpty {
            let files = turn.files.count
            put(JournalEntry(id: "turn|\(turn.pillId)|\(turn.startedAt.timeIntervalSince1970)", kind: .turn,
                             pillId: turn.pillId, title: turn.headline,
                             detail: [turn.project, files == 0 ? nil : (files == 1 ? "1 file" : "\(files) files")]
                                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                             date: turn.endedAt ?? turn.startedAt, tone: turn.endedAt == nil ? .info : .ok, url: nil,
                             themes: [.code]))
        }
        for (pillId, snapshot) in services {
            for section in snapshot.sections {
                for item in section.items {
                    guard let date = item.date, date <= Date() else { continue }
                    var themes = Self.themes(for: pillId)
                    if item.tone == .error { themes.append(.errors) }
                    put(JournalEntry(id: "service|\(pillId)|\(item.title)|\(Int(date.timeIntervalSince1970))",
                                     kind: .service, pillId: pillId, title: item.title, detail: item.detail,
                                     date: date, tone: item.tone, url: item.url, themes: themes))
                }
            }
        }

        let oldest = Date().addingTimeInterval(-Self.keepDays * 86_400)
        let kept = byID.values.filter { $0.date >= oldest }
        if kept.count != byID.count { changed = true }
        guard changed else { return }
        entries = Array(kept.sorted { $0.date > $1.date }.prefix(Self.maxEntries))
        save()
    }

    private static func themes(for pillId: String) -> [JournalEntry.Theme] {
        switch pillId {
        case "integration_stripe", "integration_crypto": [.money]
        case "integration_vercel": [.deploys]
        case "integration_github": [.code]
        default: []
        }
    }

    private func save() {
        let snapshot = entries
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: Journal.fileURL, options: .atomic)
        }
    }
}
