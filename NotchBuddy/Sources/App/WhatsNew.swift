import Foundation

// "What's new" after Coucou updated itself (GitHub build): once, in the notch, what the version
// brings (Resources/whats-new.json, one entry per release, in every language), then what you did
// with Coucou so far, from what is already on this Mac (nothing is sent anywhere). Pure Foundation
// so tests/WhatsNewTests.swift checks the rules: which entry, which language, fresh install or
// update, which numbers are worth showing.

enum WhatsNew {
    struct Item: Decodable, Equatable, Sendable {
        let icon: String
        let title: [String: String]
        let detail: [String: String]
    }

    struct Release: Decodable, Equatable, Sendable {
        let version: String
        let items: [Item]
    }

    private struct File: Decodable {
        let releases: [Release]
    }

    /// The releases in whats-new.json; nothing when it doesn't read.
    static func releases(_ data: Data) -> [Release] {
        (try? JSONDecoder().decode(File.self, from: data))?.releases ?? []
    }

    /// The entry of this version ("0.6" and "0.6.0" are the same).
    static func release(for version: String, in releases: [Release]) -> Release? {
        releases.first { !MacUpdate.isNewer($0.version, than: version) && !MacUpdate.isNewer(version, than: $0.version) }
    }

    // MARK: - When

    /// Show it when the running version is newer than the last one this Mac saw. Coucou 0.5.2 and
    /// earlier kept no version: then an install that was used before counts as an update, a new
    /// one (nothing used yet) doesn't.
    static func shouldShow(lastSeen: String?, current: String, usedBefore: Bool) -> Bool {
        if let lastSeen { return MacUpdate.isNewer(current, than: lastSeen) }
        return usedBefore
    }

    // MARK: - Language

    /// The app's language first ("pt-BR", "zh-Hant"), then shorter forms of it, then English.
    static func text(_ values: [String: String], languages: [String]) -> String {
        for lang in languages {
            var parts = lang.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
            while !parts.isEmpty {
                if let v = values[parts.joined(separator: "-")], !v.isEmpty { return v }
                parts.removeLast()
            }
        }
        return values["en"] ?? values.values.sorted().first ?? ""
    }

    // MARK: - Icons

    /// The icons whats-new.json may name (scripts/test-whats-new.py has the same list), as SF Symbols.
    static let symbols: [String: String] = [
        "update": "arrow.down.circle.fill",
        "languages": "globe",
        "terminal": "terminal.fill",
        "checklist": "checklist",
        "bell": "bell.badge.fill",
        "chat": "bubble.left.and.bubble.right.fill",
        "mic": "mic.fill",
        "phone": "iphone",
        "shield": "lock.shield.fill",
        "sparkles": "sparkles",
        "bolt": "bolt.fill",
        "puzzle": "puzzlepiece.extension.fill",
        "paint": "paintpalette.fill",
        "eye": "eye.fill",
        "keyboard": "keyboard.fill",
        "heart": "heart.fill",
        "clock": "clock.fill",
        "download": "shippingbox.fill",
        "bug": "ladybug.fill",
    ]

    static func symbol(_ icon: String) -> String { symbols[icon] ?? "sparkles" }

    // MARK: - Your Coucou so far

    struct Stats: Equatable, Sendable {
        var sessions = 0
        var agentMinutes = 0
        var linesAdded = 0
        var approvals = 0
        var words = 0
        var minutesSaved = 0
        var notes = 0
    }

    enum Chip: Equatable, Sendable {
        case sessions(Int), agentTime(minutes: Int), lines(Int), approvals(Int)
        case words(Int), saved(minutes: Int), notes(Int)
    }

    /// The numbers worth showing, at most six: nothing that is zero, agents first, then Flow.
    static func chips(_ s: Stats, max: Int = 6) -> [Chip] {
        var out: [Chip] = []
        if s.sessions > 0 { out.append(.sessions(s.sessions)) }
        if s.agentMinutes >= 1 { out.append(.agentTime(minutes: s.agentMinutes)) }
        if s.linesAdded > 0 { out.append(.lines(s.linesAdded)) }
        if s.approvals > 0 { out.append(.approvals(s.approvals)) }
        if s.words > 0 { out.append(.words(s.words)) }
        if s.minutesSaved >= 1 { out.append(.saved(minutes: s.minutesSaved)) }
        if s.notes > 0 { out.append(.notes(s.notes)) }
        return Array(out.prefix(max))
    }

    // MARK: - Links

    /// "Buy Mochi a coffee": the same Stripe page as coucou's site and README.
    static let coffeeURL = URL(string: "https://buy.stripe.com/dRm6oGbfa7Kqcqs0hxes003")!

    static func releasePage(_ version: String) -> URL {
        URL(string: "https://github.com/\(MacUpdate.owner)/\(MacUpdate.repo)/releases/tag/v\(version)")!
    }
}
