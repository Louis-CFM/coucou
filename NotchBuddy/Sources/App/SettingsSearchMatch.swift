import Foundation

/// How the search of the Coucou window matches a box (pure, tested by scripts/test-settings-search.sh).
///
/// Every word typed must be somewhere in the box: its title, its page or one of its labels,
/// whatever the case and the accents ("reglage" finds "Réglage"), and a piece of a word is
/// enough ("volu" finds "Volume").
enum SettingsSearchMatch: Equatable {
    /// The box itself: the words are all in its title or its page.
    case box
    /// A setting inside the box: the label the words point at.
    case label(String)

    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The words of a query, normalized.
    static func words(_ query: String) -> [String] {
        query.split(whereSeparator: { $0.isWhitespace }).map { normalize(String($0)) }.filter { !$0.isEmpty }
    }

    /// nil when the box doesn't have every word.
    static func match(_ words: [String], title: String, page: String, labels: [String]) -> SettingsSearchMatch? {
        guard !words.isEmpty else { return nil }
        let head = normalize(title + " " + page)
        let texts = labels.map(normalize)
        let all = ([head] + texts).joined(separator: " ")
        guard words.allSatisfy({ all.contains($0) }) else { return nil }
        if words.allSatisfy({ head.contains($0) }) { return .box }
        // The label with the most of the words, the first one when tied.
        var best: (index: Int, count: Int)?
        for (i, text) in texts.enumerated() {
            let count = words.filter { text.contains($0) }.count
            if count > 0, count > (best?.count ?? 0) { best = (i, count) }
        }
        guard let best else { return .box }
        return .label(labels[best.index])
    }
}
