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

struct AskQuestion: Equatable {
    var questions: [AskQuestionItem]   // 1–4 questions

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
    // Single-select: one label; multi-select: joined by ", ".
    // Custom text answers arrive pre-keyed: selections[i] = [customText].
    static func buildAnswers(questions: [AskQuestionItem], selections: [[String]]) -> [String: String] {
        var answers: [String: String] = [:]
        for (i, item) in questions.enumerated() {
            guard i < selections.count, !selections[i].isEmpty else { continue }
            answers[item.question] = selections[i].joined(separator: ", ")
        }
        return answers
    }
}
