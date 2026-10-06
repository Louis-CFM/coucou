import Foundation
import AppKit

/// One finished agent session persisted for the Today pulse / history strip.
struct FinishedSession: Codable, Equatable, Identifiable {
    var id: String
    var pillId: String
    var name: String
    var endedAt: Date
    var finalLine: String?
    var summary: String?          // "+N −M in K files"
    var filePaths: [String]       // up to 5
    var outcome: String           // "ok" | "error"

    var addedRemoved: (added: Int, removed: Int)? {
        guard let summary else { return nil }
        // "+42 −11 in 3 files"
        let parts = summary.split(separator: " ")
        guard parts.count >= 2,
              let a = Int(parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "+"))),
              let r = Int(parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "−-")))
        else { return nil }
        return (a, abs(r))
    }
}

/// Rolling local store of finished sessions (Application Support JSON). No cloud / telemetry.
@MainActor
final class SessionHistoryStore: ObservableObject {
    static let shared = SessionHistoryStore()

    @Published private(set) var sessions: [FinishedSession] = []

    private let maxEntries = 30
    private let maxAge: TimeInterval = 36 * 3600

    private var fileURL: URL {
        HookServer.supportDir.appendingPathComponent("session-history.json")
    }

    private init() {
        load()
    }

    var todaySessions: [FinishedSession] {
        sessions.filter { Calendar.current.isDateInToday($0.endedAt) }
            .sorted { $0.endedAt > $1.endedAt }
    }

    var todayPulseText: String? {
        let today = todaySessions
        guard !today.isEmpty else { return nil }
        var added = 0, removed = 0
        for s in today {
            if let ar = s.addedRemoved { added += ar.added; removed += ar.removed }
        }
        let n = today.count
        var bits = ["\(n) session\(n == 1 ? "" : "s")"]
        if added > 0 || removed > 0 { bits.append("+\(added) −\(removed)") }
        return bits.joined(separator: " · ")
    }

    var recentFilePaths: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for s in todaySessions {
            for p in s.filePaths where !seen.contains(p) {
                seen.insert(p)
                out.append(p)
                if out.count >= 8 { return out }
            }
        }
        return out
    }

    func record(pillId: String, name: String, finalLine: String?, summary: String?,
                filePaths: [String], outcome: String) {
        let entry = FinishedSession(
            id: UUID().uuidString,
            pillId: pillId,
            name: name,
            endedAt: Date(),
            finalLine: finalLine,
            summary: summary,
            filePaths: Array(filePaths.prefix(5)),
            outcome: outcome
        )
        sessions.insert(entry, at: 0)
        prune()
        save()
    }

    func prune() {
        let cutoff = Date().addingTimeInterval(-maxAge)
        sessions = Array(sessions.filter { $0.endedAt >= cutoff }.prefix(maxEntries))
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([FinishedSession].self, from: data) else {
            sessions = []
            return
        }
        sessions = decoded
        prune()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: HookServer.supportDir,
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Cursor shell Always allowlist (cwd + command fingerprint)

struct CursorShellAllowEntry: Codable, Equatable, Identifiable {
    var id: String          // fingerprint
    var cwd: String
    var command: String
    var createdAt: Date
}

enum CursorShellAllowlist {
    private static let udKey = "cursorShellAllowlist"

    static func fingerprint(cwd: String, command: String) -> String {
        let norm = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(cwd)\u{1f}\(norm)"
    }

    static func load() -> [CursorShellAllowEntry] {
        guard let data = UserDefaults.standard.data(forKey: udKey),
              let list = try? JSONDecoder().decode([CursorShellAllowEntry].self, from: data)
        else { return [] }
        return list
    }

    static func save(_ list: [CursorShellAllowEntry]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: udKey)
        }
    }

    static func contains(cwd: String, command: String) -> Bool {
        let fp = fingerprint(cwd: cwd, command: command)
        return load().contains { $0.id == fp }
    }

    static func add(cwd: String, command: String) {
        var list = load()
        let fp = fingerprint(cwd: cwd, command: command)
        guard !list.contains(where: { $0.id == fp }) else { return }
        list.insert(CursorShellAllowEntry(id: fp, cwd: cwd, command: command, createdAt: Date()), at: 0)
        if list.count > 200 { list = Array(list.prefix(200)) }
        save(list)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: udKey)
    }

    static func remove(id: String) {
        var list = load()
        list.removeAll { $0.id == id }
        save(list)
    }
}

// MARK: - Open path in editor (shared by diff card + ⌃⌥E)

enum FileOpener {
    static func open(path: String, atLine line: Int? = nil) {
        #if !APPSTORE
        let codePaths = ["/opt/homebrew/bin/code", "/usr/local/bin/code", "/usr/bin/code",
                         "\(NSHomeDirectory())/.nvm/current/bin/code"]
        if let codePath = codePaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: codePath)
            if let line {
                p.arguments = ["-g", "\(path):\(line)"]
            } else {
                p.arguments = [path]
            }
            try? p.run()
            return
        }
        #endif
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}
