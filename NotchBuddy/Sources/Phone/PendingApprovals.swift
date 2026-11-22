import Foundation

/// The approvals waiting on this iPhone, shared with the notification service through the app
/// group. The iCloud alert for an approval carries only the agent and an opaque fingerprint
/// (the command stays encrypted in iCloud); the app, woken by the same push, writes the rest here
/// and the service puts it in the banner.
enum PendingApprovals {
    struct Item: Codable, Equatable {
        var agent: String
        var project: String
        var command: String
        var pillId: String
    }

    private static let key = "pendingApprovals"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: "group.fr.louisraille.Coucou") }

    static func save(_ items: [String: Item]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults?.set(data, forKey: key)
    }

    static func load() -> [String: Item] {
        guard let data = defaults?.data(forKey: key),
              let items = try? JSONDecoder().decode([String: Item].self, from: data) else { return [:] }
        return items
    }
}
