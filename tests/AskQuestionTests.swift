import Foundation

@main
enum AskQuestionTests {

    static var failures = 0

    static func check(_ label: String, _ got: String, _ expected: String) {
        if got == expected {
            print("  ✓ \(label)")
        } else {
            print("  ✗ \(label)")
            print("    got:      \(got.debugDescription)")
            print("    expected: \(expected.debugDescription)")
            failures += 1
        }
    }

    static func checkTrue(_ label: String, _ value: Bool) {
        if value { print("  ✓ \(label)") }
        else      { print("  ✗ \(label)"); failures += 1 }
    }

    static func main() {
        let opt1: [String: Any] = ["label": "Postgres", "description": "Full-text search"]
        let opt2: [String: Any] = ["label": "Meilisearch", "description": ""]
        let opt3: [String: Any] = ["label": "Algolia", "description": "Managed search"]

        // ── parse ──────────────────────────────────────────────────────────────
        print("AskQuestion.parse")

        let single: [String: Any] = ["questions": [
            ["question": "Which search engine?", "header": "Search", "options": [opt1, opt2, opt3], "multiSelect": false]
        ]]
        let parsed = AskQuestion.parse(toolInput: single)
        checkTrue("single question parses",           parsed != nil)
        checkTrue("question text",                    parsed?.questions[0].question == "Which search engine?")
        checkTrue("header",                           parsed?.questions[0].header == "Search")
        checkTrue("3 options",                        parsed?.questions[0].options.count == 3)
        checkTrue("multiSelect false",                parsed?.questions[0].multiSelect == false)
        checkTrue("option label",                     parsed?.questions[0].options[0].label == "Postgres")

        // header truncated at 12 chars
        let longHeader: [String: Any] = ["questions": [
            ["question": "Q?", "header": "This is a very long header", "options": [opt1, opt2], "multiSelect": false]
        ]]
        let lh = AskQuestion.parse(toolInput: longHeader)
        checkTrue("header truncated to 12",           lh?.questions[0].header.count == 12)

        // multiSelect true
        let multi: [String: Any] = ["questions": [
            ["question": "Pick features", "header": "Features", "options": [opt1, opt2, opt3], "multiSelect": true]
        ]]
        let mParsed = AskQuestion.parse(toolInput: multi)
        checkTrue("multiSelect true",                 mParsed?.questions[0].multiSelect == true)

        // 4 questions (max)
        let q: [String: Any] = ["question": "Q?", "header": "", "options": [opt1, opt2], "multiSelect": false]
        let four: [String: Any] = ["questions": [q, q, q, q]]
        checkTrue("4 questions parses",               AskQuestion.parse(toolInput: four) != nil)

        // 5 questions → nil (over max)
        let five: [String: Any] = ["questions": [q, q, q, q, q]]
        checkTrue("5 questions → nil",                AskQuestion.parse(toolInput: five) == nil)

        // 1 option → nil (under min)
        let oneOpt: [String: Any] = ["questions": [
            ["question": "Q?", "header": "", "options": [opt1], "multiSelect": false]
        ]]
        checkTrue("1 option → nil",                   AskQuestion.parse(toolInput: oneOpt) == nil)

        // missing question text → nil
        let noQ: [String: Any] = ["questions": [
            ["header": "", "options": [opt1, opt2], "multiSelect": false]
        ]]
        checkTrue("missing question → nil",           AskQuestion.parse(toolInput: noQ) == nil)

        // empty questions array → nil
        checkTrue("empty questions → nil",            AskQuestion.parse(toolInput: ["questions": []]) == nil)

        // missing questions key → nil
        checkTrue("missing questions → nil",          AskQuestion.parse(toolInput: [:]) == nil)

        // option with empty label → nil
        let emptyLabel: [String: Any] = ["questions": [
            ["question": "Q?", "header": "", "options": [["label": "", "description": ""], opt2], "multiSelect": false]
        ]]
        checkTrue("empty option label → nil",         AskQuestion.parse(toolInput: emptyLabel) == nil)

        // ── buildAnswers ───────────────────────────────────────────────────────
        print("AskQuestion.buildAnswers")

        let items = AskQuestion.parse(toolInput: multi)!.questions
        + AskQuestion.parse(toolInput: single)!.questions

        // items[0] = "Pick features" (multiSelect: true), items[1] = "Which search engine?" (multiSelect: false)
        let sel1 = [["Postgres"], ["Meilisearch"]]
        let ans1 = AskQuestion.buildAnswers(questions: items, selections: sel1)
        checkTrue("multi-select single pick → [String]",  (ans1["Pick features"] as? [String]) == ["Postgres"])
        checkTrue("single-select answer → String",        (ans1["Which search engine?"] as? String) == "Meilisearch")

        // Multi-select with multiple picks → [String] array
        let sel2 = [["Postgres", "Algolia"], []]
        let ans2 = AskQuestion.buildAnswers(questions: items, selections: sel2)
        checkTrue("multi-select multiple picks → [String]", (ans2["Pick features"] as? [String]) == ["Postgres", "Algolia"])
        checkTrue("unanswered question omitted",            ans2["Which search engine?"] == nil)

        // Empty selections → empty dict
        let ans3 = AskQuestion.buildAnswers(questions: items, selections: [[], []])
        checkTrue("all empty → empty dict",               ans3.isEmpty)

        // ── finish ─────────────────────────────────────────────────────────────
        if failures == 0 {
            print("\nAll tests passed.")
            exit(0)
        } else {
            print("\n\(failures) test(s) failed.")
            exit(1)
        }
    }
}
