import Foundation

// What the iPhone shows for one service Mochi (GitHub, Stripe, Vercel, Resend,
// Cal.com, n8n, Notion): its state dot, why it has that color, and the latest
// items the Mac fetched. The Mac builds it from the data its pollers already
// keep (ServicePublisher) and writes it to the private iCloud zone, encrypted;
// the iPhone only reads it. No API key ever leaves the Mac.

enum ServiceTone: String, Codable, Sendable {
    case ok, warning, error, info, idle
}

struct ServiceItem: Codable, Equatable, Sendable {
    var title: String
    var detail: String = ""
    var tone: ServiceTone = .idle
    var date: Date? = nil
    var url: String? = nil
}

struct ServiceSection: Codable, Equatable, Sendable {
    var title: String
    var items: [ServiceItem]
}

struct ServiceSnapshot: Codable, Equatable, Sendable {
    var pillId: String
    var tone: ServiceTone
    /// One line under the name ("Balance 1 240,00 EUR", "2 pull requests").
    var headline: String
    /// Why the dot has its color ("CI failing on coucou · main").
    var reason: String
    var sections: [ServiceSection]
    var updatedAt: Date

    static let recordType = "Service"

    static func recordName(for pillId: String) -> String { "service-\(pillId)" }

    static func pillId(fromRecordName name: String) -> String? {
        name.hasPrefix("service-") ? String(name.dropFirst("service-".count)) : nil
    }

    /// Equal apart from the date: nothing to write again.
    func sameContent(as other: ServiceSnapshot) -> Bool {
        var a = self, b = other
        a.updatedAt = .distantPast
        b.updatedAt = .distantPast
        return a == b
    }
}

extension PillCatalog {
    /// The service Mochi the iPhone shows, in this order.
    static let phoneServices = [
        "integration_github", "integration_stripe", "integration_vercel", "integration_resend",
        "integration_calcom", "integration_n8n", "integration_notion",
    ]

    /// Agent sessions (VS Code, Cursor, Codex…), as opposed to services and chat providers.
    static func isSession(_ id: String) -> Bool {
        switch definition(for: id)?.category {
        case .service, .ai: false
        default: true
        }
    }
}
