import Foundation

// The search box of the Coucou window: what you type finds a page or a setting, in the
// language you read it in or in English. This file is only the matching, with no view and no
// catalog in it, so a script can test it alone (Tests/HubSearchTests.swift).

/// A page or a setting the search can lead to.
struct HubSearchCandidate<Page: Hashable> {
    let page: Page
    /// The names to look in: the one shown first (the current language), then the English one.
    let names: [String]
    /// What the result says.
    let text: String
    /// "Notch · General".
    let place: String
    /// The setting to underline once the page is open; nil for a page itself.
    let find: String?
}

struct HubSearchHit<Page: Hashable>: Identifiable {
    let id: String
    let page: Page
    let text: String
    let place: String
    let find: String?
}

enum HubSearchCore {
    static let maxHits = 20

    /// Lower case, without the accents: "Réglages" and "reglages" are the same word.
    static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
    }

    /// 0 when the name starts with the query, 1 at the start of a word, 2 anywhere; nil when it is not there.
    private static func rank(_ query: String, _ tokens: [String], _ names: [String]) -> Int? {
        guard let shown = names.first else { return nil }
        if shown.hasPrefix(query) { return 0 }
        if " \(shown)".contains(" \(query)") { return 1 }
        let all = names.joined(separator: " ")
        return tokens.allSatisfy { all.contains($0) } ? 2 : nil
    }

    /// The candidates that match `query`, the best first. Every word of the query has to be in the
    /// name, in the current language or in English.
    static func search<Page: Hashable>(_ query: String, in candidates: [HubSearchCandidate<Page>]) -> [HubSearchHit<Page>] {
        let tokens = normalize(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return [] }
        let wanted = tokens.joined(separator: " ")
        var found: [(rank: Int, order: Int, hit: HubSearchHit<Page>)] = []
        for (order, candidate) in candidates.enumerated() {
            guard let r = rank(wanted, tokens, candidate.names.map(normalize)) else { continue }
            found.append((r, order, HubSearchHit(id: "\(order)", page: candidate.page, text: candidate.text,
                                                 place: candidate.place, find: candidate.find)))
        }
        // At the same rank, the pages and then the settings keep their order.
        found.sort { ($0.rank, $0.order) < ($1.rank, $1.order) }
        return found.prefix(maxHits).map(\.hit)
    }
}
