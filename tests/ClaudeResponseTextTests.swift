import Foundation

@main
enum ClaudeResponseTextTests {
    static func main() {
        var executedCaseCount = 0

        @discardableResult
        func expectText(_ name: String, content: [[String: Any]], expected: String?) -> String? {
            let actual = claudeResponseText(fromContent: content)
            precondition(actual == expected,
                         "\(name): expected \(String(reflecting: expected)), got \(String(reflecting: actual))")
            executedCaseCount += 1
            return actual
        }

        func expectJSON(_ name: String, fragments: [String], expected: String) -> [String: Any] {
            let content = fragments.map { ["type": "text", "text": $0] }
            let text = expectText(name, content: content, expected: expected)!
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                preconditionFailure("\(name): combined text must remain valid JSON")
            }
            return parsed
        }

        expectText("single text block", content: [
            ["type": "text", "text": "Simple answer."]
        ], expected: "Simple answer.")

        // Separators belong to the response text, not to content-block boundaries.
        expectText("web search keeps preamble and answer", content: [
            ["type": "text", "text": "I'll look that up.\n"],
            ["type": "server_tool_use", "id": "srvtoolu_01", "name": "web_search", "input": ["query": "test"]],
            ["type": "web_search_tool_result", "tool_use_id": "srvtoolu_01", "content": []],
            ["type": "text", "text": "The answer is 42."]
        ], expected: "I'll look that up.\nThe answer is 42.")

        expectText("empty leading block does not hide the answer", content: [
            ["type": "text", "text": ""],
            ["type": "server_tool_use", "id": "srvtoolu_02", "name": "web_search"],
            ["type": "web_search_tool_result", "tool_use_id": "srvtoolu_02", "content": []],
            ["type": "text", "text": "Here is the actual answer."]
        ], expected: "Here is the actual answer.")

        expectText("several search rounds preserve text order", content: [
            ["type": "text", "text": "First.\n"],
            ["type": "web_search_tool_result", "tool_use_id": "a", "content": []],
            ["type": "text", "text": "Second.\n"],
            ["type": "web_search_tool_result", "tool_use_id": "b", "content": []],
            ["type": "text", "text": "Third."]
        ], expected: "First.\nSecond.\nThird.")

        expectText("search result content does not leak into the answer", content: [
            ["type": "text", "text": "Answer."],
            ["type": "web_search_tool_result", "tool_use_id": "a", "content": [
                ["type": "web_search_result", "title": "Some page", "text": "Search result text."]
            ]]
        ], expected: "Answer.")

        expectText("tool-only response", content: [
            ["type": "server_tool_use", "id": "x", "name": "web_search"]
        ], expected: nil)
        expectText("empty response", content: [], expected: nil)

        expectText("whitespace-only text", content: [
            ["type": "text", "text": "  \n\t "]
        ], expected: nil)
        expectText("several empty or whitespace-only blocks", content: [
            ["type": "text", "text": ""],
            ["type": "text", "text": "  "]
        ], expected: nil)

        expectText("outer whitespace is trimmed", content: [
            ["type": "text", "text": "  padded  "]
        ], expected: "padded")
        expectText("internal newlines are preserved", content: [
            ["type": "text", "text": " keep\ninner\nspaces "]
        ], expected: "keep\ninner\nspaces")

        expectText("missing text value is skipped", content: [
            ["type": "text"],
            ["type": "text", "text": "Real one."]
        ], expected: "Real one.")
        expectText("non-string text value is skipped", content: [
            ["type": "text", "text": 42],
            ["type": "text", "text": "After."]
        ], expected: "After.")

        expectText("Unicode survives concatenation", content: [
            ["type": "text", "text": "Café ☕ — "],
            ["type": "text", "text": "مرحبا"]
        ], expected: "Café ☕ — مرحبا")

        // handleResult extracts the outer braces before parsing the final JSON answer.
        let json = expectText("JSON after a search remains extractable", content: [
            ["type": "text", "text": "Let me check.\n"],
            ["type": "web_search_tool_result", "tool_use_id": "x", "content": []],
            ["type": "text", "text": "{\"title\":\"Release notes\",\"items\":[]}"]
        ], expected: "Let me check.\n{\"title\":\"Release notes\",\"items\":[]}")!
        let braces = json.firstIndex(of: "{")!...json.lastIndex(of: "}")!
        let parsed = try? JSONSerialization.jsonObject(with: Data(String(json[braces]).utf8)) as? [String: Any]
        precondition(parsed?["title"] as? String == "Release notes",
                     "JSON after a search: brace-extracted title must remain parseable")

        // Anthropic's web-search response example has adjacent sentence fragments,
        // with citations attached to one text block rather than a paragraph break.
        expectText("citation boundary does not insert a line break", content: [
            ["type": "text", "text": "Based on the search results, "],
            ["type": "text", "text": "the release is available.", "citations": [
                ["type": "web_search_result_location", "url": "https://example.com/release", "title": "Release"]
            ]]
        ], expected: "Based on the search results, the release is available.")

        expectText("a word split across blocks is reconstructed", content: [
            ["type": "text", "text": "Concate"],
            ["type": "text", "text": "nation works."]
        ], expected: "Concatenation works.")

        // Defensive synthetic cases: no live API occurrence is claimed for these JSON splits.
        let splitString = expectJSON("synthetic split JSON string", fragments: [
            "{\"title\":\"Release ", "notes\",\"items\":[]}"
        ], expected: "{\"title\":\"Release notes\",\"items\":[]}")
        precondition(splitString["title"] as? String == "Release notes",
                     "synthetic split JSON string: title must be reconstructed")

        let splitEscape = expectJSON("synthetic split JSON escape sequence", fragments: [
            "{\"title\":\"Line\\", "nBreak\"}"
        ], expected: #"{"title":"Line\nBreak"}"#)
        precondition(splitEscape["title"] as? String == "Line\nBreak",
                     "synthetic split JSON escape sequence: escape must decode to a newline")

        let splitNumber = expectJSON("synthetic split JSON number", fragments: [
            "{\"value\":12", ".5}"
        ], expected: "{\"value\":12.5}")
        precondition(splitNumber["value"] as? Double == 12.5,
                     "synthetic split JSON number: value must remain 12.5")

        expectText("a whitespace-only interior block is retained", content: [
            ["type": "text", "text": "First"],
            ["type": "text", "text": " \n\t "],
            ["type": "text", "text": "Second"]
        ], expected: "First \n\t Second")

        expectText("only the combined text's outer edges are trimmed", content: [
            ["type": "text", "text": " \nFirst  "],
            ["type": "text", "text": "  second\t "]
        ], expected: "First    second")

        expectText("markdown formatting survives block boundaries", content: [
            ["type": "text", "text": "# Heading\n\n```sw"],
            ["type": "text", "text": "ift\nlet answer = 42\n"],
            ["type": "text", "text": "```\n\n- Item"]
        ], expected: "# Heading\n\n```swift\nlet answer = 42\n```\n\n- Item")

        expectText("non-text blocks with a text field are ignored", content: [
            ["type": "server_tool_use", "text": "Tool metadata."],
            ["type": "thinking", "text": "Thinking metadata."],
            ["text": "Missing type."],
            ["type": "text", "text": "Answer."]
        ], expected: "Answer.")

        print("Claude response text: \(executedCaseCount) cases passed")
    }
}
