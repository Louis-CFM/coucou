#if !APPSTORE
import Foundation

/// One thing Coucou did to a message: shown in the Mail section, with its Undo.
struct MailJournalEntry: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var date: Date
    var account: String
    var fromMailbox: String
    var sender: String
    var subject: String
    /// The message's Message-ID, to find it again for Undo ("" when Mail gave none).
    var rfcId: String
    var action: MailRuleAction
    var reason: MailReason
    var undone = false
}

/// A mail Coucou sent for the chat (a plan the user ran).
struct MailSentEntry: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var date: Date
    var to: [String]
    var subject: String
    var attachments: [String]
}

/// The Mail section's settings (rules, banned words, VIPs, automatic sorting) and the journal of
/// what Coucou sorted. JSON files in Application Support/NotchBuddy/Mail, on this Mac only.
@MainActor
final class MailTriageStore: ObservableObject {
    static let shared = MailTriageStore()

    @Published var settings = MailTriageSettings() {
        didSet {
            guard settings != oldValue else { return }
            save(settings, to: "triage.json")
            if !loading && settings.autoSort != oldValue.autoSort { MailController.shared.triageSettingsChanged() }
        }
    }
    /// Newest first, the last 500.
    @Published private(set) var journal: [MailJournalEntry] = []
    /// What Coucou sent for the chat, newest first, the last 500.
    @Published private(set) var sent: [MailSentEntry] = []

    /// Messages already looked at by the automatic sorting (Mail's ids), so each one is
    /// sorted once and a message put back by hand is left alone.
    private var seen: [String] = []
    private var seenSet = Set<String>()
    private var loading = false

    static var folder: URL { HookServer.supportDir.appendingPathComponent("Mail", isDirectory: true) }

    private init() {
        loading = true
        settings = load(MailTriageSettings.self, from: "triage.json") ?? MailTriageSettings()
        journal = load([MailJournalEntry].self, from: "journal.json") ?? []
        sent = load([MailSentEntry].self, from: "sent.json") ?? []
        seen = load([String].self, from: "seen.json") ?? []
        seenSet = Set(seen)
        loading = false
    }

    // MARK: - Settings

    func setAutoSort(_ on: Bool) {
        var s = settings
        s.autoSort = on
        // Only what arrives from now on: Coucou never goes through the old messages.
        if on { s.autoSortSince = Date() }
        settings = s
    }

    func addBanned(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !settings.banned.contains(where: { MailTriage.normalize($0) == MailTriage.normalize(w) }) else { return }
        settings.banned.append(w)
    }

    func addVIP(_ entry: String) {
        let e = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !e.isEmpty, !settings.vip.contains(where: { MailTriage.normalize($0) == MailTriage.normalize(e) }) else { return }
        settings.vip.append(e)
    }

    // MARK: - Seen messages

    func isSeen(_ id: String) -> Bool { seenSet.contains(id) }

    func markSeen(_ ids: [String]) {
        let fresh = ids.filter { !seenSet.contains($0) }
        guard !fresh.isEmpty else { return }
        seen.append(contentsOf: fresh)
        fresh.forEach { seenSet.insert($0) }
        if seen.count > 4000 {
            seen.removeFirst(seen.count - 4000)
            seenSet = Set(seen)
        }
        save(seen, to: "seen.json")
    }

    // MARK: - Journal

    func record(_ entry: MailJournalEntry) {
        journal.insert(entry, at: 0)
        if journal.count > 500 { journal.removeLast(journal.count - 500) }
        save(journal, to: "journal.json")
    }

    func recordSent(_ entry: MailSentEntry) {
        sent.insert(entry, at: 0)
        if sent.count > 500 { sent.removeLast(sent.count - 500) }
        save(sent, to: "sent.json")
    }

    func markUndone(_ id: UUID) {
        guard let i = journal.firstIndex(where: { $0.id == id }) else { return }
        journal[i].undone = true
        save(journal, to: "journal.json")
    }

    func clearJournal() {
        journal = []
        save(journal, to: "journal.json")
    }

    /// New messages the automatic sorting looked at today, matched or not (the Overview shows
    /// it while nothing was sorted: it is working, nothing matched).
    @Published private(set) var checkedToday: Int = {
        let d = UserDefaults.standard
        return d.string(forKey: "mailCheckedDay") == MailTriageStore.dayKey() ? d.integer(forKey: "mailCheckedCount") : 0
    }()

    func countChecked(_ n: Int) {
        let d = UserDefaults.standard
        let day = Self.dayKey()
        let base = d.string(forKey: "mailCheckedDay") == day ? d.integer(forKey: "mailCheckedCount") : 0
        d.set(day, forKey: "mailCheckedDay")
        d.set(base + n, forKey: "mailCheckedCount")
        checkedToday = base + n
    }

    nonisolated private static func dayKey() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    /// What was sorted today, for the Overview.
    var today: (sorted: Int, junk: Int, important: Int) {
        let start = Calendar.current.startOfDay(for: Date())
        let entries = journal.filter { $0.date >= start && !$0.undone }
        return (entries.count,
                entries.filter { $0.action == .junk }.count,
                entries.filter { $0.action == .important }.count)
    }

    // MARK: - Files

    private func save<T: Encodable>(_ value: T, to name: String) {
        guard !loading else { return }
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(value).write(to: Self.folder.appendingPathComponent(name), options: .atomic)
        } catch {
            appendAppLog("nb.log", "[Mail] could not save \(name): \(error.localizedDescription)")
        }
    }

    private func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: Self.folder.appendingPathComponent(name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }
}
#endif
