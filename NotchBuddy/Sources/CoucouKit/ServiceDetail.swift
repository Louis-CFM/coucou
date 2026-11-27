import Foundation

// A service seen up close, for the iPhone: figures, lists and what can be
// done from there. When a service's screen opens, the iPhone asks the Mac for
// it (a `ServiceAction` record of kind "refresh"); the Mac reads the service's
// API with the key in its Keychain and writes a `ServiceDetail` record,
// encrypted. An action (redeploy, re-run, merge…) is the same kind of record:
// the Mac runs it only if the iPhone asked for one it offered on that item,
// then writes the detail again with the result. No key ever leaves the Mac.

struct ServiceActionDef: Codable, Equatable, Sendable, Hashable {
    /// What the Mac does, e.g. "vercel.redeploy", "github.merge".
    var kind: String
    var title: String
    var symbol: String
    /// The thing it acts on (deployment id, "owner/repo#12"…).
    var target: String
    var destructive: Bool = false
    /// Asked before doing it, when it can't be undone.
    var confirm: String? = nil
}

struct DetailStat: Codable, Equatable, Sendable {
    var label: String
    var value: String
    var tone: ServiceTone = .idle
}

struct DetailItem: Codable, Equatable, Sendable {
    var title: String
    var subtitle: String = ""
    var tone: ServiceTone = .idle
    var date: Date? = nil
    var url: String? = nil
    /// A short tag on the right ("Production", "Draft", "Active"…).
    var badge: String? = nil
    var actions: [ServiceActionDef] = []
    /// Its own page on the iPhone: what it is, field by field ("Fee 0,55 €", "From Payment link"…).
    /// Optional, so details written before them still decode.
    var fields: [DetailStat]? = nil
    /// And the lists inside it (a project's deployments, a repo's CI runs).
    var sections: [DetailSection]? = nil

    /// Opens a page of its own on the iPhone (instead of going straight to the web).
    var hasPage: Bool { !(fields ?? []).isEmpty || !(sections ?? []).isEmpty }
}

struct DetailSection: Codable, Equatable, Sendable {
    var title: String
    var items: [DetailItem]
    var footer: String? = nil
}

struct ServiceActionResult: Codable, Equatable, Sendable {
    var title: String
    var ok: Bool
    var message: String
    var date: Date
}

struct ServiceDetail: Codable, Equatable, Sendable {
    var pillId: String
    var stats: [DetailStat] = []
    var sections: [DetailSection] = []
    var fetchedAt: Date
    /// Why the API couldn't be read (no key, 401…).
    var error: String? = nil
    var lastAction: ServiceActionResult? = nil
    /// The month shown ("2026-10"), for services read month by month (Stripe); nil otherwise.
    var period: String? = nil

    static let recordType = "ServiceDetail"
    static let requestType = "ServiceAction"
    static let refreshKind = "refresh"

    static func recordName(for pillId: String) -> String { "detail-\(pillId)" }

    static func pillId(fromRecordName name: String) -> String? {
        name.hasPrefix("detail-") ? String(name.dropFirst("detail-".count)) : nil
    }

    /// The action offered on one of the items, if the Mac offered it.
    func offered(kind: String, target: String) -> ServiceActionDef? {
        for section in sections {
            for item in section.items {
                if let action = item.actions.first(where: { $0.kind == kind && $0.target == target }) { return action }
            }
        }
        return nil
    }
}

/// A month as the iPhone and the Mac name it: "2026-10", in the Mac's calendar.
enum ServicePeriod {
    static func key(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    /// The first instant of the month and of the next one.
    static func range(of key: String, calendar: Calendar = .current) -> (start: Date, end: Date)? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, (1...12).contains(parts[1]),
              let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)),
              let end = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
        return (start, end)
    }

    static func shifted(_ key: String, by months: Int, calendar: Calendar = .current) -> String {
        guard let start = range(of: key, calendar: calendar)?.start,
              let moved = calendar.date(byAdding: .month, value: months, to: start) else { return key }
        return self.key(for: moved, calendar: calendar)
    }

    /// "November 2026".
    static func name(of key: String, calendar: Calendar = .current) -> String {
        guard let start = range(of: key, calendar: calendar)?.start else { return key }
        return start.formatted(.dateTime.month(.wide).year())
    }
}
