import Foundation

// The sessions the iPhone app hands to its widgets, through the App Group
// container. Compiled into both the app and the CoucouWidgets extension.

struct SharedSession: Codable, Identifiable, Hashable, Sendable {
    let id: String          // pill ID
    let title: String       // project name, or the agent's name
    let agent: String       // "VS Code", "Codex"…
    let color: String       // agent color, hex
    let state: String       // BotState raw value
    let statusText: String  // "working · 3/7", "waiting for your OK"…
    let tone: Tone
    let urgency: Int        // lower = more urgent
    let stepIndex: Int
    let stepCount: Int
    let currentStep: String
    let updatedAt: Date

    enum Tone: String, Codable, Sendable {
        case waiting, question, error, working, done, idle
    }

    var isWaitingForYou: Bool { tone == .waiting || tone == .question }
    var isWorking: Bool { tone == .working }

    /// Opens one session in the app (widgets link here).
    static func url(for id: String) -> URL {
        URL(string: "coucou://session/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)")!
    }

    /// The session id in a coucou://session/<id> link.
    static func sessionId(from url: URL) -> String? {
        guard url.scheme == "coucou", url.host == "session" else { return nil }
        let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return id.isEmpty ? nil : id
    }

    /// Agents before services when equally urgent: the team shows who codes first.
    var categoryRank: Int {
        switch PillCatalog.definition(for: id)?.category {
        case .workspace: 0
        case .agent: 1
        case .service: 2
        default: 3
        }
    }
}

enum SharedSessions {
    static let appGroup = "group.fr.louisraille.Coucou"

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("sessions.json")
    }

    static func save(_ sessions: [SharedSession]) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Most urgent first.
    static func load() -> [SharedSession] {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let sessions = try? JSONDecoder().decode([SharedSession].self, from: data) else { return [] }
        return sessions.sorted {
            ($0.urgency, $0.categoryRank, $1.updatedAt) < ($1.urgency, $1.categoryRank, $0.updatedAt)
        }
    }
}

extension Array where Element == SharedSession {
    /// "2 working · 1 waiting", or nil when nothing is going on.
    var summary: String? {
        let waiting = filter(\.isWaitingForYou).count
        let working = filter(\.isWorking).count
        var parts: [String] = []
        if working > 0 { parts.append("\(working) working") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
