import CryptoKit
import Foundation

// A question Claude Code asks (AskUserQuestion), as the iPhone gets it: the
// questions with their choices. The Mac writes it, encrypted, in the session
// record; the iPhone answers with an `Answer` record carrying the same
// fingerprint and the labels picked. The Mac only accepts labels that are
// among the choices of the question still waiting.

struct QuestionPayload: Codable, Equatable, Sendable {
    struct Option: Codable, Equatable, Sendable {
        var label: String
        var description: String
    }

    struct Item: Codable, Equatable, Sendable {
        var question: String
        var header: String
        var options: [Option]
        var multiSelect: Bool
    }

    var items: [Item]

    /// Stable identifier of this exact question.
    var fingerprint: String {
        let raw = items.map { item in
            ([item.question, item.multiSelect ? "multi" : "single"] + item.options.map(\.label)).joined(separator: "\u{1F}")
        }.joined(separator: "\u{1E}")
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var json: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ json: String) -> QuestionPayload? {
        guard !json.isEmpty else { return nil }
        return try? JSONDecoder().decode(QuestionPayload.self, from: Data(json.utf8))
    }

    /// The picks sent back: one list of labels per question.
    static func encodeSelections(_ selections: [[String]]) -> String {
        guard let data = try? JSONEncoder().encode(selections) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeSelections(_ json: String) -> [[String]]? {
        try? JSONDecoder().decode([[String]].self, from: Data(json.utf8))
    }

    /// True when every pick is one of that question's choices, with one pick
    /// per single-choice question.
    func accepts(_ selections: [[String]]) -> Bool {
        guard selections.count == items.count else { return false }
        for (item, picks) in zip(items, selections) {
            let labels = Set(item.options.map(\.label))
            guard !picks.isEmpty, picks.allSatisfy(labels.contains) else { return false }
            if !item.multiSelect && picks.count != 1 { return false }
        }
        return true
    }
}
