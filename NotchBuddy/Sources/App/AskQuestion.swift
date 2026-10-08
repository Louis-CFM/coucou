import Foundation

// MARK: - AskUserQuestion model (Foundation-only, testable)

struct AskQuestionOption: Equatable {
    var label: String
    var description: String
}

struct AskQuestionItem: Equatable {
    var question: String    // full question text
    var header: String      // ≤12 chars; used as section label
    var options: [AskQuestionOption]   // 2–4 choices
    var multiSelect: Bool
}

/// Island height of the pending question, readable from the nonisolated `islandSize`. Written on the main actor only.
enum QuestionLayout {
    nonisolated(unsafe) static var height: CGFloat?
}

extension AskQuestionItem {
    /// True when at least one option carries a description: the card then lists options vertically.
    var hasDescriptions: Bool { options.contains { !$0.description.isEmpty } }
}

struct AskQuestion: Equatable {
    var questions: [AskQuestionItem]   // 1–4 questions

    /// Island height that fits the tallest question without truncation (rough estimate, text wraps at ~500 pt).
    var estimatedIslandHeight: CGFloat {
        func lines(_ text: String, charWidth: CGFloat) -> CGFloat {
            max(1, (CGFloat(text.count) * charWidth / 500).rounded(.up))
        }
        let tallest = questions.map { item -> CGFloat in
            var h: CGFloat = 20 + lines(item.question, charWidth: 7) * 17 + 64
            if !item.header.isEmpty { h += 14 }
            if item.hasDescriptions {
                for opt in item.options {
                    h += 34 + (opt.description.isEmpty ? 0 : lines(opt.description, charWidth: 6.4) * 14)
                }
                h += 40   // "Other…" row
            } else {
                h += item.options.count >= 3 ? 74 : 40
            }
            if item.multiSelect { h += 34 }
            return h
        }.max() ?? 160
        return min(max(tallest, 160), 560)
    }

    // MARK: - Parse from tool_input dict
    // Returns nil if the payload is malformed (fallback → Allow/Deny card).
    static func parse(toolInput: [String: Any]) -> AskQuestion? {
        guard let rawQs = toolInput["questions"] as? [[String: Any]],
              !rawQs.isEmpty, rawQs.count <= 4 else { return nil }
        var items: [AskQuestionItem] = []
        for raw in rawQs {
            guard let question = raw["question"] as? String, !question.isEmpty,
                  let rawOpts = raw["options"] as? [[String: Any]],
                  rawOpts.count >= 2, rawOpts.count <= 4 else { return nil }
            var opts: [AskQuestionOption] = []
            for opt in rawOpts {
                guard let label = opt["label"] as? String, !label.isEmpty else { return nil }
                let desc = opt["description"] as? String ?? ""
                opts.append(AskQuestionOption(label: label, description: desc))
            }
            let rawHeader = raw["header"] as? String ?? ""
            let header = String(rawHeader.prefix(12))
            let multi = raw["multiSelect"] as? Bool ?? false
            items.append(AskQuestionItem(question: question, header: header, options: opts, multiSelect: multi))
        }
        return AskQuestion(questions: items)
    }

    // MARK: - Build answers dict
    // selections[i] = list of labels selected for question[i].
    // Single-select / Other…: one label → String value (Claude Code 2.1.85+).
    // Multi-select: array of labels → [String] value (Claude Code 2.1.136+).
    static func buildAnswers(questions: [AskQuestionItem], selections: [[String]]) -> [String: Any] {
        var answers: [String: Any] = [:]
        for (i, item) in questions.enumerated() {
            guard i < selections.count, !selections[i].isEmpty else { continue }
            if item.multiSelect {
                answers[item.question] = selections[i]          // array for multi-select
            } else {
                answers[item.question] = selections[i][0]       // string for single-select
            }
        }
        return answers
    }
}
