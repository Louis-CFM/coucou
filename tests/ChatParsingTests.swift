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

        print("LocalChat.streamEndpoint")
        let local = LocalChat.streamEndpoint(baseURL: "http://localhost:11434", apiKey: nil)
        check("local URL adds /v1",       local.url,           "http://localhost:11434/v1/chat/completions")
        check("local sends Bearer ollama", local.authorization, "Bearer ollama")
        let emptyKey = LocalChat.streamEndpoint(baseURL: "http://localhost:1234", apiKey: "")
        check("empty key = local",        emptyKey.authorization, "Bearer ollama")
        let deepseek = LocalChat.streamEndpoint(baseURL: "https://api.deepseek.com/v1", apiKey: "sk-deep")
        check("cloud URL keeps its /v1",  deepseek.url,           "https://api.deepseek.com/v1/chat/completions")
        check("cloud sends its key",      deepseek.authorization, "Bearer sk-deep")
        let qwen = LocalChat.streamEndpoint(baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", apiKey: "sk-qwen")
        check("qwen URL",                 qwen.url,           "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")
        check("qwen sends its key",       qwen.authorization, "Bearer sk-qwen")

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

        markdownCases()

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

        print("LocalChat.streamChat — cloud provider sends its key (fake server)")

        // A cloud base URL ends with /v1 (https://api.deepseek.com/v1); the fake
        // server answers 401 unless the bearer token is the key passed here.
        do {
            let response = try await LocalChat.streamChat(
                baseURL: baseURL + "/v1",
                model: "deepseek-chat",
                messages: [["role": "user", "content": "hello"]],
                apiKey: "sk-test-cloud-key",
                onToken: { _ in }
            )
            checkTrue("cloud stream authenticated, reply whole", response.contains("## Answer"))
        } catch {
            print("  ✗ unexpected error: \(error)")
            failures += 1
        }

        do {
            _ = try await LocalChat.streamChat(
                baseURL: baseURL + "/v1",
                model: "deepseek-chat",
                messages: [["role": "user", "content": "hello"]],
                apiKey: "sk-wrong-key",
                onToken: { _ in }
            )
            print("  ✗ should have thrown for a wrong key")
            failures += 1
        } catch let e as LocalChatError {
            if case .serverError(let msg) = e {
                checkTrue("wrong key → server's auth message", msg.contains("Authentication Fails"))
            } else {
                print("  ✗ wrong error case: \(e)")
                failures += 1
            }
        } catch {
            print("  ✗ unexpected error type: \(error)")
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


    // MARK: - Markdown cases (section 7.1 of the plan)

    private static func eq(_ label: String, _ got: [MDBlock], _ expected: [MDBlock]) {
        if got == expected { print("  ✓ \(label)") }
        else {
            print("  ✗ \(label)")
            print("    got:      \(got)")
            print("    expected: \(expected)")
            failures += 1
        }
    }

    private static func blocksOf(_ text: String, streaming: Bool = false) -> [MDBlock] {
        ChatMarkdown.parse(text, streaming: streaming)
    }

    private static func code(_ blocks: [MDBlock]) -> (lang: String, code: String)? {
        for b in blocks { if case .codeBlock(let l, let c) = b { return (l, c) } }
        return nil
    }

    private static func markdownCases() {
        print("ChatMarkdown.parse — tables")
        eq("1 table header, delimiter, two rows",
           blocksOf("| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |"),
           [.table(header: ["A", "B"], align: [.leading, .leading], rows: [["1", "2"], ["3", "4"]])])
        eq("2 alignment",
           blocksOf("| a | b | c |\n|:--|:-:|--:|\n| 1 | 2 | 3 |"),
           [.table(header: ["a", "b", "c"], align: [.leading, .center, .trailing], rows: [["1", "2", "3"]])])
        eq("3 no leading and trailing pipes",
           blocksOf("a | b\n--- | ---\n1 | 2"),
           [.table(header: ["a", "b"], align: [.leading, .leading], rows: [["1", "2"]])])
        eq("4 escaped pipe is a literal pipe",
           blocksOf("| a | b |\n|---|---|\n| x \\| y | z |"),
           [.table(header: ["a", "b"], align: [.leading, .leading], rows: [["x | y", "z"]])])
        eq("5 short row padded, long row widens the table with empty header cells",
           blocksOf("| a | b |\n|---|---|\n| 1 |\n| 1 | 2 | 3 |"),
           [.table(header: ["a", "b", ""], align: [.leading, .leading, .leading], rows: [["1", "", ""], ["1", "2", "3"]])])
        eq("6 pipe line without delimiter is a paragraph",
           blocksOf("a | b\nnot a delimiter"), [.paragraph(text: "a | b\nnot a delimiter")])
        eq("6b a sentence with a pipe stays a sentence",
           blocksOf("use a | b to pipe"), [.paragraph(text: "use a | b to pipe")])
        eq("7 table ends at a blank line",
           blocksOf("| a |\n|---|\n| 1 |\n\nafter"),
           [.table(header: ["a"], align: [.leading], rows: [["1"]]), .paragraph(text: "after")])
        let wide = (0...ChatMarkdown.maxTableColumns).map { "c\($0)" }
        let wideText = "| " + wide.joined(separator: " | ") + " |\n|" + String(repeating: "---|", count: wide.count)
        checkTrue("8 more than maxTableColumns: not a table",
                  !blocksOf(wideText).contains { if case .table = $0 { return true }; return false })
        var manyRows = "| a |\n|---|\n"
        for n in 0..<(ChatMarkdown.maxTableRows + 50) { manyRows += "| \(n) |\n" }
        if case .table(_, _, let rows)? = blocksOf(manyRows).first {
            checkTrue("8b more than maxTableRows: cut", rows.count == ChatMarkdown.maxTableRows)
        } else { print("  ✗ 8b table expected"); failures += 1 }
        eq("22 dashes right after a pipe line are the delimiter, not a rule",
           blocksOf("a | b\n---|---"), [.table(header: ["a", "b"], align: [.leading, .leading], rows: [])])
        eq("22b dashes with no pipe after a pipe line are a rule",
           blocksOf("| a |\n---"), [.paragraph(text: "| a |"), .rule])

        print("ChatMarkdown.parse — lists, tasks, rules, quotes")
        eq("9 task items",
           blocksOf("- [ ] a\n- [x] b\n* [X] c"),
           [.taskItem(checked: false, text: "a", indent: 0), .taskItem(checked: true, text: "b", indent: 0),
            .taskItem(checked: true, text: "c", indent: 0)])
        eq("10 link item is a list item",
           blocksOf("- [link](url)"), [.listItem(prefix: "•", text: "[link](url)", indent: 0)])
        eq("16a 1) is a numbered item",
           blocksOf("1) item"), [.listItem(prefix: "1.", text: "item", indent: 0)])
        eq("16b 1.item is a paragraph", blocksOf("1.item"), [.paragraph(text: "1.item")])
        eq("16c 2024. A year is item 2024 (pinned)",
           blocksOf("2024. A year"), [.listItem(prefix: "2024.", text: "A year", indent: 0)])
        eq("17 indented line continues the item",
           blocksOf("- a\n  b"), [.listItem(prefix: "•", text: "a\nb", indent: 0)])
        eq("18 non indented line is a new paragraph",
           blocksOf("- a\nb"), [.listItem(prefix: "•", text: "a", indent: 0), .paragraph(text: "b")])
        eq("17b a nested item is its own item, not a continuation",
           blocksOf("- a\n  - b"), [.listItem(prefix: "•", text: "a", indent: 0), .listItem(prefix: "•", text: "b", indent: 1)])
        eq("17c a blank line ends the item",
           blocksOf("- a\n\n  b"), [.listItem(prefix: "•", text: "a", indent: 0), .paragraph(text: "  b")])
        eq("19a tab before a marker counts as 4 columns",
           blocksOf("- a\n\t- b"), [.listItem(prefix: "•", text: "a", indent: 0), .listItem(prefix: "•", text: "b", indent: 2)])
        eq("19b indent never exceeds 6",
           blocksOf("- a\n" + String(repeating: " ", count: 40) + "- b"),
           [.listItem(prefix: "•", text: "a", indent: 0), .listItem(prefix: "•", text: "b", indent: 6)])
        eq("20 three > lines are one quote",
           blocksOf("> a\n> b\n> c"), [.quote(text: "a\nb\nc")])
        eq("20b >> is read as one level", blocksOf(">> deep"), [.quote(text: "deep")])
        for r in ["----", "- - -", "* * *", "___"] { eq("21 rule \(r)", blocksOf(r), [.rule]) }
        eq("21b `- - - x` is a list item", blocksOf("- - - x"), [.listItem(prefix: "•", text: "- - x", indent: 0)])
        eq("21c `- item` is not a rule", blocksOf("- item"), [.listItem(prefix: "•", text: "item", indent: 0)])

        print("ChatMarkdown.parse — fences, html, headings")
        let inList = blocksOf("- step\n   ```bash\n   # comment\n   echo hi\n   ```\nafter")
        let c11 = code(inList)
        checkTrue("11 indented fence in a list is a code block", c11?.lang == "bash")
        check("11b the opening indent is removed from the code", c11?.code ?? "", "# comment\necho hi")
        checkTrue("12 a # line inside the code is code, not a heading",
                  !inList.contains { if case .heading = $0 { return true }; return false })
        eq("12b the text after the fence is a paragraph",
           Array(inList.suffix(1)), [.paragraph(text: "after")])
        let tilde = blocksOf("~~~\n```\nstill code\n~~~\nx")
        eq("13 ~~~ fence holds a ``` line as code",
           tilde, [.codeBlock(lang: "", code: "```\nstill code"), .paragraph(text: "x")])
        check("14 the whole info string is shown", code(blocksOf("```python title=\"x\"\nprint(1)\n```"))?.lang ?? "", "python title=\"x\"")
        check("14b the info string is cut at maxLanguageChars",
              code(blocksOf("```" + String(repeating: "a", count: 80) + "\nx\n```"))?.lang ?? "",
              String(repeating: "a", count: ChatMarkdown.maxLanguageChars))
        eq("15 unclosed fence runs to the end", blocksOf("```swift\nlet a = 1\nlet b = 2"),
           [.codeBlock(lang: "swift", code: "let a = 1\nlet b = 2")])
        eq("15b a longer fence is closed only by an equal or longer one",
           blocksOf("````\n```\nx\n````"), [.codeBlock(lang: "", code: "```\nx")])
        eq("23 <br> inside a paragraph becomes a newline", blocksOf("a<br>b<br/>c"), [.paragraph(text: "a\nb\nc")])
        eq("23b <br> inside a table cell", blocksOf("| a |\n|---|\n| x<br>y |"),
           [.table(header: ["a"], align: [.leading], rows: [["x\ny"]])])
        for level in 1...6 {
            eq("24 heading level \(level)", blocksOf(String(repeating: "#", count: level) + " T"),
               [.heading(level: level, text: "T")])
        }
        eq("24b ####### gives level 6", blocksOf("####### T"), [.heading(level: 6, text: "T")])

        print("ChatMarkdown.parse — streaming")
        eq("26 last line ` is held back", blocksOf("text\n`", streaming: true), [.paragraph(text: "text")])
        eq("26b last line `` is held back", blocksOf("text\n``", streaming: true), [.paragraph(text: "text")])
        eq("26c without streaming it is a paragraph", blocksOf("text\n``"), [.paragraph(text: "text\n``")])
        eq("26d a closing fence arriving in pieces is held back inside code",
           blocksOf("```\nlet a\n``", streaming: true), [.codeBlock(lang: "", code: "let a")])
        eq("27 last line `| a | b |` is a table with one header row",
           blocksOf("| a | b |", streaming: true), [.table(header: ["a", "b"], align: [.leading, .leading], rows: [])])
        eq("28 half delimiter is not shown",
           blocksOf("| a | b |\n|--", streaming: true), [.table(header: ["a", "b"], align: [.leading, .leading], rows: [])])
        eq("28b the delimiter arrived: same table", blocksOf("| a | b |\n|---|---|", streaming: true),
           [.table(header: ["a", "b"], align: [.leading, .leading], rows: [])])
        eq("29 half written row is padded",
           blocksOf("| a | b |\n|---|---|\n| 1", streaming: true),
           [.table(header: ["a", "b"], align: [.leading, .leading], rows: [["1", ""]])])
        eq("30 header line then a sentence: paragraphs",
           blocksOf("| a | b |\nhello", streaming: true), [.paragraph(text: "| a | b |\nhello")])
        eq("30b the pipe line of a paragraph interrupts it as a table while streaming",
           blocksOf("intro\n| a | b |", streaming: true),
           [.paragraph(text: "intro"), .table(header: ["a", "b"], align: [.leading, .leading], rows: [])])
        eq("32z streaming closes the open inline of the last block",
           blocksOf("a **bold", streaming: true), [.paragraph(text: "a **bold**")])
        eq("32y it does not touch a finished text", blocksOf("a **bold"), [.paragraph(text: "a **bold")])

        // 31: the no flicker property, over a sample cut at every line
        let sample = """
        # Title

        Intro with **bold** and `code`.

        | Name | Qty |
        |------|----:|
        | a    | 1   |
        | b    | 2   |

        - [ ] first
        - [x] second
          continued
        1. one
        2. two

        ```python
        def f():
            return 1
        ```

        > quote
        > more

        Done.
        """
        let sampleLines = sample.components(separatedBy: "\n")
        var prefixHolds = true
        var failedAt = -1
        for k in 1..<sampleLines.count {
            let a = blocksOf(sampleLines[0..<k].joined(separator: "\n"), streaming: true)
            let b = blocksOf(sampleLines[0...k].joined(separator: "\n"), streaming: true)
            if a.count > b.count || Array(a.dropLast()) != Array(b.prefix(max(0, a.count - 1))) {
                prefixHolds = false; failedAt = k; break
            }
        }
        checkTrue("31 blocks only append or grow, over every line cut (failed at line \(failedAt))", prefixHolds)

        print("ChatMarkdown.parse — second review (M1, m1 to m6, m11, n3)")
        // M1: CRLF and lone CR
        eq("M1 CRLF text parses like LF text",
           blocksOf("# Title\r\n\r\n| a | b |\r\n|---|---|\r\n| 1 | 2 |\r\n\r\n```py\r\nx = 1\r\n```\r\nafter\r\n- item\r\n---\r\n"),
           [.heading(level: 1, text: "Title"),
            .table(header: ["a", "b"], align: [.leading, .leading], rows: [["1", "2"]]),
            .codeBlock(lang: "py", code: "x = 1"), .paragraph(text: "after"),
            .listItem(prefix: "•", text: "item", indent: 0), .rule])
        eq("M1b a lone CR is a line break", blocksOf("a\rb\r\rc"), [.paragraph(text: "a\nb"), .paragraph(text: "c")])
        // m1: a ** that cannot open is not closed
        eq("m1 src/**/*.ts is left alone", blocksOf("see src/**/*.ts", streaming: true), [.paragraph(text: "see src/**/*.ts")])
        eq("m1b x ** 2 is left alone", blocksOf("x ** 2 is", streaming: true), [.paragraph(text: "x ** 2 is")])
        eq("m1c bold over two lines is closed once, by its own closer",
           blocksOf("a **bold\nstill** b", streaming: true), [.paragraph(text: "a **bold\nstill** b")])
        eq("m1d bold opened on an earlier line is closed at the end",
           blocksOf("a **bold\nmore", streaming: true), [.paragraph(text: "a **bold\nmore**")])
        eq("m1e a plain open bold is still closed", blocksOf("a **bold", streaming: true), [.paragraph(text: "a **bold**")])
        // m2: a lone list marker is the empty item
        eq("m2 lone bullet after a blank line", blocksOf("text\n\n- ", streaming: true),
           [.paragraph(text: "text"), .listItem(prefix: "•", text: "", indent: 0)])
        eq("m2b lone number", blocksOf("text\n\n1.", streaming: true),
           [.paragraph(text: "text"), .listItem(prefix: "1.", text: "", indent: 0)])
        eq("m2c lone nested marker", blocksOf("- a\n  -", streaming: true),
           [.listItem(prefix: "•", text: "a", indent: 0), .listItem(prefix: "•", text: "", indent: 1)])
        eq("m2d without streaming a lone marker is a paragraph", blocksOf("text\n\n-"),
           [.paragraph(text: "text"), .paragraph(text: "-")])
        // m3: table in progress
        eq("m3 a sentence with a pipe then a lone dash is not a table", blocksOf("Use a | b here:\n-", streaming: true),
           [.paragraph(text: "Use a | b here:")])
        eq("m3b the dash turns into a bullet", blocksOf("Use a | b here:\n- item", streaming: true),
           [.paragraph(text: "Use a | b here:"), .listItem(prefix: "•", text: "item", indent: 0)])
        eq("m3c a header followed by a blank line is not a table", blocksOf("| a | b |\n\n", streaming: true),
           [.paragraph(text: "| a | b |")])
        eq("m3d a leading pipe header with a lone dash is a table", blocksOf("| a | b |\n-", streaming: true),
           [.table(header: ["a", "b"], align: [.leading, .leading], rows: [])])
        // m4: never shrinks, over every character cut
        let loose = "Compare: speed | cost\n---|---\nfast | high\nslow | low"
        var shrank = -1
        var prevCount = 0
        for k in 1...loose.count {
            let n = blocksOf(String(loose.prefix(k)), streaming: true).count
            if n < prevCount && shrank < 0 { shrank = k }
            prevCount = n
        }
        checkTrue("m4 table without leading pipes: the block list never shrinks (shrank at \(shrank))", shrank < 0)
        eq("m4b the last line after a loose table is a row in progress",
           blocksOf("Compare: speed | cost\n---|---\nfast ", streaming: true),
           [.table(header: ["Compare: speed", "cost"], align: [.leading, .leading], rows: [["fast", ""]])])
        eq("m4c with leading pipes the sentence after the table stays a paragraph",
           blocksOf("| a | b |\n|---|---|\n| 1 | 2 |\nhello", streaming: true),
           [.table(header: ["a", "b"], align: [.leading, .leading], rows: [["1", "2"]]), .paragraph(text: "hello")])
        // m5: <br> inside inline code
        eq("m5 <br> in a code span stays", blocksOf("Use `<br>` or <BR/> here"), [.paragraph(text: "Use `<br>` or \n here")])
        eq("m5b <br> in a table code span stays", blocksOf("| a |\n|---|\n| `x<br>y` z<br>w |"),
           [.table(header: ["a"], align: [.leading], rows: [["`x<br>y` z\nw"]])])
        // m6: nothing silently dropped
        eq("m6 cells beyond the header widen the table", blocksOf("| a | b |\n|---|---|\n| 1 | 2 | LOST? |"),
           [.table(header: ["a", "b", ""], align: [.leading, .leading, .leading], rows: [["1", "2", "LOST?"]])])
        let wideRow = "| a |\n|---|\n| " + (0..<(ChatMarkdown.maxTableColumns + 5)).map { "c\($0)" }.joined(separator: " | ") + " |"
        if case .table(let h, let al, let rows)? = blocksOf(wideRow).first {
            checkTrue("m6b widening stops at maxTableColumns",
                      h.count == ChatMarkdown.maxTableColumns && al.count == h.count && rows[0].count == h.count)
        } else { print("  ✗ m6b table expected"); failures += 1 }
        var overRows = "| a |\n|---|\n"
        for n in 0..<(ChatMarkdown.maxTableRows + 7) { overRows += "| \(n) |\n" }
        let overBlocks = blocksOf(overRows)
        checkTrue("m6c rows over the cap are counted in a hidden rows block",
                  overBlocks.count == 2 && overBlocks.last == .hiddenRows(count: 7))
        var atCap = "| a |\n|---|\n"
        for n in 0..<ChatMarkdown.maxTableRows { atCap += "| \(n) |\n" }
        checkTrue("m6d no hidden rows block at the cap exactly", blocksOf(atCap).count == 1)
        eq("m6e hash only lines stay as a paragraph", blocksOf("#\n##\n# \ntext"), [.paragraph(text: "#\n##\n# \ntext")])
        eq("m6f a lone # still arriving is held back", blocksOf("text\n\n#", streaming: true), [.paragraph(text: "text")])
        // m11: a table under a list item
        eq("m11 an indented table ends the item", blocksOf("- item\n  | a | b |\n  |---|---|\n  | 1 | 2 |"),
           [.listItem(prefix: "•", text: "item", indent: 0),
            .table(header: ["a", "b"], align: [.leading, .leading], rows: [["1", "2"]])])
        // n3: tab after a marker, bullet text trimmed
        eq("n3 tab after a bullet marker", blocksOf("-\titem"), [.listItem(prefix: "•", text: "item", indent: 0)])
        eq("n3b tab after a number", blocksOf("1.\tnum"), [.listItem(prefix: "1.", text: "num", indent: 0)])
        eq("n3c bullet text is trimmed", blocksOf("-  two spaces"), [.listItem(prefix: "•", text: "two spaces", indent: 0)])

        print("ChatMarkdown.closeOpenInline")
        check("32 bold", ChatMarkdown.closeOpenInline("a **bold"), "a **bold**")
        check("32b code", ChatMarkdown.closeOpenInline("a `code"), "a `code`")
        check("32c strike", ChatMarkdown.closeOpenInline("a ~~gone"), "a ~~gone~~")
        check("33 unfinished link shows its text", ChatMarkdown.closeOpenInline("see [docs](https://exa"), "see docs")
        check("33b unfinished link text is unchanged", ChatMarkdown.closeOpenInline("see [docs"), "see [docs")
        check("34 balanced is unchanged", ChatMarkdown.closeOpenInline("a **b** and `c` and ~~d~~"), "a **b** and `c` and ~~d~~")
        check("34b a closed code span holding ** is unchanged", ChatMarkdown.closeOpenInline("use `**` here"), "use `**` here")
        check("34c a closed link is unchanged", ChatMarkdown.closeOpenInline("[a](https://x.y)"), "[a](https://x.y)")
        check("34d an opener with nothing after it is dropped", ChatMarkdown.closeOpenInline("a **"), "a ")
        check("34e a ** inside an open code span does not count", ChatMarkdown.closeOpenInline("a `x ** y"), "a `x ** y`")
        bidiControls()
    }

    // MARK: - Bidirectional controls in code (display and Copy only)

    private static func bidiControls() {
        print("ChatMarkdown: override and isolate characters in code")
        let dirty = "ls\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069} -la"
        check("40 every override, embedding and isolate character is dropped", ChatMarkdown.withoutBidiControls(dirty), "ls -la")
        check("40b text with none is returned as it is", ChatMarkdown.withoutBidiControls("echo \"héllo\" 😀 \u{200F}x"), "echo \"héllo\" 😀 \u{200F}x")
        let blocks = ChatMarkdown.parse("```py\u{202E}thon\nrm\u{202E} -rf x\u{2066}\n```")
        if case .codeBlock(let lang, let code)? = blocks.first {
            check("41 a code block shown and copied without them: the code", code, "rm -rf x")
            check("41 ... and the info string", lang, "python")
        } else { print("  ✗ 41 no code block"); failures += 1 }
        check("42 inline code span: dropped inside, kept outside",
              ChatMarkdown.withoutBidiControlsInCodeSpans("run `ls\u{202E}x` now\u{202E}"), "run `lsx` now\u{202E}")
        check("42b a double backtick span", ChatMarkdown.withoutBidiControlsInCodeSpans("a ``x`\u{2067}y`` b"), "a ``x`y`` b")
        check("42c an unclosed span is not a span", ChatMarkdown.withoutBidiControlsInCodeSpans("a `b\u{202E}"), "a `b\u{202E}")
        check("42d two spans", ChatMarkdown.withoutBidiControlsInCodeSpans("`a\u{202E}` and `b\u{2069}`"), "`a` and `b`")
        check("42e a text with none is returned as it is", ChatMarkdown.withoutBidiControlsInCodeSpans("plain `code`"), "plain `code`")
        check("42f an escaped backtick opens no span: the real span after it is cleaned",
              ChatMarkdown.withoutBidiControlsInCodeSpans("\\` then `ls\u{202E}x`"), "\\` then `lsx`")
        check("42g two backslashes escape themselves: the backtick opens a span",
              ChatMarkdown.withoutBidiControlsInCodeSpans("\\\\`a\u{202E}b`"), "\\\\`ab`")
        check("42h three backslashes: the backtick is escaped again, the span after it is cleaned",
              ChatMarkdown.withoutBidiControlsInCodeSpans("\\\\\\` `c\u{202E}d`"), "\\\\\\` `cd`")
        let hostile = String(repeating: "`", count: 30_000) + "\u{202E}" + String(repeating: "`a", count: 30_000)
        let t0 = Date()
        _ = ChatMarkdown.withoutBidiControlsInCodeSpans(hostile)
        checkTrue("42f many unclosed backticks stay linear (\(Int(Date().timeIntervalSince(t0) * 1000)) ms)", Date().timeIntervalSince(t0) < 2)
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
