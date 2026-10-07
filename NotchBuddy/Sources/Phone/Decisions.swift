import Foundation
import LocalAuthentication

enum Decision: String, Codable, Sendable {
    case allow, deny
}

/// One decision taken on this iPhone (kept on the iPhone only).
struct DecisionLog: Codable, Identifiable, Sendable {
    var id = UUID()
    let decision: Decision
    let pillId: String
    let summary: String     // the command, shortened
    let date: Date

    private static let key = "decisionHistory"

    static func load() -> [DecisionLog] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let logs = try? JSONDecoder().decode([DecisionLog].self, from: data) else { return [] }
        return logs
    }

    static func save(_ logs: [DecisionLog]) {
        if let data = try? JSONEncoder().encode(logs) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// Face ID (or the passcode) before allowing a command. Never skipped.
enum OwnerCheck {
    static func confirm(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
