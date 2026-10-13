import Foundation

// MARK: - LinearReason

/// Why an inbox entry exists, from the notification's public `category`.
enum LinearReason: String, Equatable {
    case mention, assigned, comment, status, reaction, reminder, other

    init(category: String?) {
        switch category {
        case "mentions":           self = .mention
        case "assignments":        self = .assigned
        case "commentsAndReplies": self = .comment
        case "statusChanges":      self = .status
        case "reactions":          self = .reaction
        case "reminders":          self = .reminder
        default:                   self = .other
        }
    }

    var symbol: String {
        switch self {
        case .mention:  return "at"
        case .assigned: return "person.crop.circle"
        case .comment:  return "bubble.left"
        case .status:   return "circle.dashed"
        case .reaction: return "face.smiling"
        case .reminder: return "bell"
        case .other:    return "tray"
        }
    }
}

// MARK: - Models

struct LinearNotification: Identifiable, Equatable {
    let id: String
    let reason: LinearReason
    let actor: String?
    let key: String?        // "ENG-123"; nil for project entries
    let title: String
    let url: String
    let createdAt: Date
}

struct LinearInbox: Equatable {
    var unread: [LinearNotification]
    var inboxURL: String

    static let endpoint = "https://api.linear.app/graphql"

    /// Unread state and snoozing are not filterable server-side: both are applied in `parse`.
    /// The docs do not say which way `first` counts, so the window is read from both ends.
    static let query = """
    query CoucouInbox {
      newest: notifications(first: 100, filter: { createdAt: { gt: "-P14D" } }) { nodes { ...Entry } }
      oldest: notifications(last: 100, filter: { createdAt: { gt: "-P14D" } }) { nodes { ...Entry } }
      viewer { organization { urlKey } }
    }
    fragment Entry on Notification {
      id
      category
      readAt
      snoozedUntilAt
      createdAt
      actor { name }
      ... on IssueNotification { issue { identifier title url } }
      ... on ProjectNotification { project { name url } }
    }
    """

    static func requestBody() -> Data? {
        try? JSONSerialization.data(withJSONObject: ["query": query])
    }

    /// nil when the response carries GraphQL errors or no data.
    static func parse(_ data: Data, now: Date = Date()) -> LinearInbox? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["errors"] == nil,
              let root = json["data"] as? [String: Any] else { return nil }

        let viewer = root["viewer"] as? [String: Any]
        let urlKey = (viewer?["organization"] as? [String: Any])?["urlKey"] as? String
        let inboxURL = urlKey.map { "https://linear.app/\($0)/inbox" } ?? "https://linear.app"

        var seen = Set<String>()
        let rawNotes = ["newest", "oldest"]
            .flatMap { ((root[$0] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? [] }
            .filter { seen.insert($0["id"] as? String ?? "").inserted }
        let unread = rawNotes
            .compactMap { parseNotification($0, inboxURL: inboxURL, now: now) }
            .sorted { $0.createdAt > $1.createdAt }

        return LinearInbox(unread: unread, inboxURL: inboxURL)
    }

    private static func parseNotification(_ n: [String: Any], inboxURL: String, now: Date) -> LinearNotification? {
        guard let id = n["id"] as? String,
              let createdAt = date(n["createdAt"]) else { return nil }
        if n["readAt"] is String { return nil }
        if let snoozed = date(n["snoozedUntilAt"]), snoozed > now { return nil }

        let actor = (n["actor"] as? [String: Any])?["name"] as? String
        let reason = LinearReason(category: n["category"] as? String)

        if let issue = n["issue"] as? [String: Any],
           let key = issue["identifier"] as? String,
           let title = issue["title"] as? String {
            return LinearNotification(id: id, reason: reason, actor: actor, key: key, title: title,
                                      url: (issue["url"] as? String) ?? inboxURL, createdAt: createdAt)
        }
        if let project = n["project"] as? [String: Any], let name = project["name"] as? String {
            return LinearNotification(id: id, reason: reason, actor: actor, key: nil, title: name,
                                      url: (project["url"] as? String) ?? inboxURL, createdAt: createdAt)
        }
        return LinearNotification(id: id, reason: reason, actor: actor, key: nil,
                                  title: String(localized: "Inbox"), url: inboxURL, createdAt: createdAt)
    }

    private static func date(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s)
    }

    /// Unread entries the previous poll had not seen; empty on the first poll.
    static func fresh(_ unread: [LinearNotification], seen: Set<String>?) -> [LinearNotification] {
        guard let seen else { return [] }
        return unread.filter { !seen.contains($0.id) }
    }
}

// MARK: - Time

func linearTimeAgo(_ date: Date, now: Date = Date()) -> String {
    let diff = now.timeIntervalSince(date)
    if diff < 60 { return "now" }
    if diff < 3600 { return "\(Int(diff / 60))m" }
    if diff < 86400 { return "\(Int(diff / 3600))h" }
    return "\(Int(diff / 86400))d"
}
