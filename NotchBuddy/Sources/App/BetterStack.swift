import Foundation

// MARK: - Better Stack
// Models and parsing for the Better Stack Uptime API (JSON:API shape:
// `data[].id` + `data[].attributes`). Foundation only, so
// NotchBuddy/Tests/BetterStackTests.swift can compile it on its own.

struct BetterStackIncident: Identifiable, Equatable {
    let id: String
    let name: String
    let cause: String?
    let startedAt: Date?
    let acknowledged: Bool

    func webURL(team: String?) -> URL? { BetterStackAPI.page("incidents/\(id)", team: team) }

    var timeAgo: String {
        guard let startedAt else { return "" }
        let diff = Date().timeIntervalSince(startedAt)
        if diff < 60    { return "just now" }
        if diff < 3600  { return "\(Int(diff/60))m" }
        if diff < 86400 { return "\(Int(diff/3600))h" }
        return "\(Int(diff/86400))d"
    }
}

struct BetterStackMonitor: Identifiable, Equatable {
    let id: String
    let name: String

    func webURL(team: String?) -> URL? { BetterStackAPI.page("monitors/\(id)", team: team) }
}

/// What changed between two polls of the open incidents.
enum BetterStackChange: Equatable {
    case none
    case opened(BetterStackIncident)
    case resolved(name: String)
}

enum BetterStackAPI {
    static let incidentsURL = URL(string: "https://incidents.betterstack.com/api/v3/incidents?resolved=false&per_page=50")!
    static let monitorsURL  = URL(string: "https://incidents.betterstack.com/api/v2/monitors?per_page=250")!
    static let dashboardURL = URL(string: "https://uptime.betterstack.com/incidents")!

    /// "t5969" from what was typed in Settings: the team ID, its number, or a dashboard link.
    /// The API never returns it, and a page link without it is a 404.
    static func team(from raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = text.range(of: #"/team/t?[0-9]+(/|$)"#, options: .regularExpression)
            .map { String(text[$0]).replacingOccurrences(of: "/team/", with: "").trimmingCharacters(in: ["/"]) } ?? text
        guard id.range(of: #"^t?[0-9]+$"#, options: .regularExpression) != nil else { return nil }
        return id.hasPrefix("t") ? id : "t" + id
    }

    /// One of the team's pages; the incident list when no team is set.
    static func page(_ path: String, team: String?) -> URL? {
        guard let team else { return dashboardURL }
        return URL(string: "https://incidents.betterstack.com/team/\(team)/\(path)")
    }

    /// Open incidents, newest first. Nil when the body isn't a JSON:API list.
    static func incidents(from data: Data) -> [BetterStackIncident]? {
        guard let rows = dataRows(data) else { return nil }
        let parsed: [BetterStackIncident] = rows.compactMap { row in
            guard let id = rowId(row), let a = row["attributes"] as? [String: Any] else { return nil }
            // `resolved=false` already filters; a resolved row is still dropped if one slips in.
            if let resolved = a["resolved_at"] as? String, !resolved.isEmpty { return nil }
            let name = (a["name"] as? String) ?? (a["url"] as? String) ?? "Incident"
            return BetterStackIncident(id: id,
                                       name: name,
                                       cause: a["cause"] as? String,
                                       startedAt: date(a["started_at"]),
                                       acknowledged: a["acknowledged_at"] as? String != nil)
        }
        return parsed.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }

    /// Monitors whose checks are failing (`status == "down"`).
    static func downMonitors(from data: Data) -> [BetterStackMonitor]? {
        guard let rows = dataRows(data) else { return nil }
        return rows.compactMap { row in
            guard let id = rowId(row), let a = row["attributes"] as? [String: Any],
                  a["status"] as? String == "down" else { return nil }
            let name = (a["pronounceable_name"] as? String) ?? (a["url"] as? String) ?? "Monitor"
            return BetterStackMonitor(id: id, name: name)
        }
    }

    /// A newly opened incident wins over a resolved one. The first poll
    /// (`previous == nil`) only fills the card.
    static func change(previous: [String: String]?, current: [BetterStackIncident]) -> BetterStackChange {
        guard let previous else { return .none }
        if let opened = current.first(where: { previous[$0.id] == nil }) { return .opened(opened) }
        let open = Set(current.map(\.id))
        if let gone = previous.first(where: { !open.contains($0.key) }) { return .resolved(name: gone.value) }
        return .none
    }

    // MARK: Helpers

    private static func dataRows(_ data: Data) -> [[String: Any]]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["data"] as? [[String: Any]]
    }

    /// JSON:API ids are strings, but accept a number too.
    private static func rowId(_ row: [String: Any]) -> String? {
        if let s = row["id"] as? String { return s }
        if let n = row["id"] as? Int { return String(n) }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s)
    }
}
