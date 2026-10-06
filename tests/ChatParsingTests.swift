import Foundation

// MARK: - Test harness

@main
enum ChatParsingTests {

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

    // MARK: - Entry point

    static func main() async {

        // ── Unit tests (no network) ──────────────────────────────────────────

        print("LocalChat.normaliseURL")
        check("strips trailing slash", LocalChat.normaliseURL("http://localhost:11434/"),      "http://localhost:11434")
        check("strips /api suffix",    LocalChat.normaliseURL("http://localhost:11434/api"),   "http://localhost:11434")
        check("strips /v1 suffix",     LocalChat.normaliseURL("http://localhost:1234/v1"),     "http://localhost:1234")
        check("no-op clean URL",       LocalChat.normaliseURL("http://localhost:11434"),       "http://localhost:11434")
        check("trims whitespace",      LocalChat.normaliseURL("  http://localhost:11434  "),   "http://localhost:11434")

        print("LocalChat.parseSSEDelta")
        let sseData = #"data: {"id":"1","choices":[{"delta":{"content":"hello"}}]}"#
        check("parses delta",          LocalChat.parseSSEDelta(sseData) ?? "", "hello")
        checkTrue("ignores [DONE]",    LocalChat.parseSSEDelta("data: [DONE]") == nil)
        checkTrue("ignores non-data",  LocalChat.parseSSEDelta(": heartbeat") == nil)
        checkTrue("ignores null content",
                  LocalChat.parseSSEDelta(#"data: {"choices":[{"delta":{"content":null}}]}"#) == nil)
        checkTrue("ignores missing content",
                  LocalChat.parseSSEDelta(#"data: {"choices":[{"delta":{}}]}"#) == nil)

        print("LocalChat.filterThinkingBlocks")
        check("removes closed block",
              LocalChat.filterThinkingBlocks("<think>internal</think>answer"), "answer")
        check("no-op without block",
              LocalChat.filterThinkingBlocks("hello"), "hello")
        check("multiline block",
              LocalChat.filterThinkingBlocks("<think>\nstep1\nstep2\n</think>result"), "result")

        print("LocalChat.progressiveFilter")
        check("open block → hide",
              LocalChat.progressiveFilter("<think>\nstep one"), "")
        check("open after text → keep prefix",
              LocalChat.progressiveFilter("visible<think>hidden"), "visible")
        check("closed block removed",
              LocalChat.progressiveFilter("<think>done</think>answer"), "answer")

        print("ChatMarkdown.parse")
        let blocks = ChatMarkdown.parse(
            "## Hello\n\nThis is a paragraph.\n\n- item 1\n- item 2\n\n```swift\nlet x = 1\n```")
        checkTrue("heading count",    blocks.filter { if case .heading   = $0 { return true }; return false }.count == 1)
        checkTrue("paragraph count",  blocks.filter { if case .paragraph = $0 { return true }; return false }.count == 1)
        checkTrue("list item count",  blocks.filter { if case .listItem  = $0 { return true }; return false }.count == 2)
        checkTrue("code block count", blocks.filter { if case .codeBlock = $0 { return true }; return false }.count == 1)
        if case .heading(let level, let text) =
            blocks.first(where: { if case .heading = $0 { return true }; return false })! {
            checkTrue("heading level 2", level == 2)
            checkTrue("heading text",    text == "Hello")
        } else { print("  ✗ heading not found"); failures += 1 }

        print("ChatMarkdown.parse — extended")
        // Numbered list preserves number
        let numBlocks = ChatMarkdown.parse("1. first\n2. second")
        let numItems = numBlocks.filter { if case .listItem = $0 { return true }; return false }
        checkTrue("ordered list count", numItems.count == 2)
        if case .listItem(let prefix, _, _) = numItems.first! {
            checkTrue("ordered prefix is '1.'", prefix == "1.")
        }
        // Heading requires space after #
        checkTrue("heading with space", ChatMarkdown.parse("## Hi").contains { if case .heading = $0 { return true }; return false })
        checkTrue("#nospace is paragraph", ChatMarkdown.parse("#nospace").contains { if case .paragraph = $0 { return true }; return false })
        // Nested list indent
        let nested = ChatMarkdown.parse("- top\n  - nested")
        let items = nested.filter { if case .listItem = $0 { return true }; return false }
        checkTrue("nested list count", items.count == 2)
        if case .listItem(_, _, let indent) = items[1] { checkTrue("nested indent = 1", indent == 1) }
        // Blockquote
        let qBlocks = ChatMarkdown.parse("> quoted text")
        checkTrue("blockquote parsed", qBlocks.contains { if case .quote = $0 { return true }; return false })
        if case .quote(let text) = qBlocks.first! { checkTrue("quote text", text == "quoted text") }
        // Paragraph stops before ordered list
        let mixBlocks = ChatMarkdown.parse("intro\n1. item")
        checkTrue("paragraph + ordered list", mixBlocks.filter { if case .paragraph = $0 { return true }; return false }.count == 1
                  && mixBlocks.filter { if case .listItem = $0 { return true }; return false }.count == 1)
        // progressiveFilter hides open think block
        check("open think → empty",  LocalChat.progressiveFilter("<think>\nhalf"), "")
        check("open after text",     LocalChat.progressiveFilter("answer<think>hidden"), "answer")
        check("closed think removed", LocalChat.progressiveFilter("<think>done</think>result"), "result")

        // ── End-to-end tests (fake server) ───────────────────────────────────

        let baseURL: String = {
            guard CommandLine.arguments.count > 1 else { return "" }
            return "http://127.0.0.1:\(CommandLine.arguments[1])"
        }()

        guard !baseURL.isEmpty else {
            print("\n(Skipping end-to-end tests — no server port provided.)")
            finish()
        }

        print("LocalChat.fetchModels (fake server)")

        let models = await LocalChat.fetchModels(baseURL: baseURL)
        checkTrue("models list non-empty",     !models.isEmpty)
        checkTrue("llama3.2 present",          models.contains { $0.id == "llama3.2" })
        checkTrue("nomic-embed-text filtered", !models.contains { $0.id == "nomic-embed-text" })

        print("LocalChat.streamChat — happy path (fake server)")

        var tokens: [String] = []
        do {
            let response = try await LocalChat.streamChat(
                baseURL: baseURL,
                model: "llama3.2",
                messages: [["role": "user", "content": "hello"]],
                onToken: { visible in tokens.append(visible) }
            )
            checkTrue("sent multiple tokens",        tokens.count > 1)
            checkTrue("intermediate tokens non-empty",  tokens.contains { !$0.isEmpty })
            checkTrue("think block removed from response",  !response.contains("<think>"))
            checkTrue("markdown heading in response",        response.contains("## Answer"))
            checkTrue("list item in response",              response.contains("- **item 1**"))
            checkTrue("code block in response",             response.contains("```python"))
        } catch {
            print("  ✗ unexpected error: \(error)")
            failures += 1
        }

        print("LocalChat.streamChat — unknown model (fake server)")

        do {
            _ = try await LocalChat.streamChat(
                baseURL: baseURL,
                model: "unknown-model",
                messages: [["role": "user", "content": "hello"]],
                onToken: { _ in }
            )
            print("  ✗ should have thrown for unknown model")
            failures += 1
        } catch let e as LocalChatError {
            if case .modelNotFound(let m) = e {
                checkTrue("model name in error", m == "unknown-model")
            } else {
                print("  ✗ wrong error case: \(e)")
                failures += 1
            }
        } catch {
            print("  ✗ unexpected error type: \(error)")
            failures += 1
        }

        print("LocalChat.streamChat — unreachable server")

        do {
            _ = try await LocalChat.streamChat(
                baseURL: "http://127.0.0.1:1",   // nothing on port 1
                model: "llama3.2",
                messages: [["role": "user", "content": "hello"]],
                onToken: { _ in }
            )
            print("  ✗ should have thrown for unreachable server")
            failures += 1
        } catch let e as LocalChatError {
            if case .serverUnreachable = e {
                print("  ✓ serverUnreachable error")
            } else {
                print("  ✗ wrong error case: \(e)")
                failures += 1
            }
        } catch {
            print("  ✗ unexpected error type: \(error)")
            failures += 1
        }

        finish()
    }

    // MARK: - Finish

    private static func finish() -> Never {
        if failures == 0 {
            print("\nAll tests passed.")
            exit(0)
        } else {
            print("\n\(failures) test(s) failed.")
            exit(1)
        }
    }
}
