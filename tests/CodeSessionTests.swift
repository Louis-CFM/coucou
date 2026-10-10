import Foundation

@main
struct CodeSessionTests {
    static func main() {
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            if ok { print("  ✓ \(name)") } else { print("  ✗ \(name)"); failures += 1 }
        }

        // Phases follow the tools a turn uses
        var s = CodeSession(project: "shop", root: "/work/shop")
        s.toolStarted(tool: "Read", input: ["file_path": "/work/shop/src/cart.ts"], cwd: "/work/shop")
        s.toolStarted(tool: "Edit", input: ["file_path": "/work/shop/src/cart.ts",
                                            "old_string": "const VAT = 0.2", "new_string": "const VAT = 0.24"], cwd: "/work/shop")
        check(s.seen == [.read, .edit] && s.current == .edit, "phases seen in order, current is the last")
        check(s.edit?.file == "src/cart.ts" && s.edit?.removed == "const VAT = 0.2", "edit kept relative to the session folder")

        s.toolStarted(tool: "Bash", input: ["command": "npm test"], cwd: "/work/shop/src")
        check(s.command?.status == .running && s.current == .bash, "a command runs")
        s.toolFinished(tool: "Bash", response: ["stdout": "a\n\n\u{1b}[32mPASS\u{1b}[0m tests/cart.test.ts\n  ✓ adds VAT (3 ms)\nTests: 1 passed\n"],
                       failed: false, error: nil)
        check(s.command?.status == .ok && s.command?.tail == ["PASS tests/cart.test.ts", "  ✓ adds VAT (3 ms)", "Tests: 1 passed"],
              "the last three lines, without colours")
        s.endTurn()
        check(s.finished && s.hasContent, "the turn ends, the view keeps what it showed")
        s.beginTurn()
        check(!s.hasContent && s.seen.isEmpty && !s.finished, "a new prompt starts clean")

        // A failed command shows why
        s.toolStarted(tool: "Bash", input: ["command": "make"], cwd: "/work/shop")
        s.toolFinished(tool: "Bash", response: nil, failed: true, error: "make: *** No rule to make target\nmore")
        check(s.command?.status == .failed && s.command?.tail == ["make: *** No rule to make target"], "failure keeps the first error line")

        // Output tail
        check(CodeView.tail(of: ["stdout": "", "stderr": "boom"]) == ["boom"], "stderr when stdout is empty")
        check(CodeView.tail(of: ["stdout": " \n"]).isEmpty, "nothing printed, nothing shown")
        check(CodeView.tail(of: "plain\ntext") == ["plain", "text"], "a string response")
        check(CodeView.tail(of: ["stdout": String(repeating: "x", count: 500)]).first?.count == 160, "long lines cut")

        // Snippet around an edit
        let text = "l1\nl2\nl3\nconst X = 2\nreturn X\nl6\nl7\nl8\n"
        let snip = CodeView.snippet(in: text, find: "const X = 2\nreturn X", context: 2)
        check(snip == CodeSnippet(start: 2, lines: ["l2", "l3", "const X = 2", "return X", "l6", "l7"], at: 2, len: 2),
              "the block with two lines of context")
        check(CodeView.snippet(in: text, find: "missing", context: 2) == nil, "text not in the file")
        check(CodeView.snippet(in: text, find: "", context: 2) == nil, "empty edit")

        // Rows in file order: removed lines before the added block, numbers from the file
        var edit = CodeEdit(isWrite: false, path: "/work/shop/a.ts", file: "a.ts", removed: "const X = 1", added: "const X = 2\nreturn X")
        edit.snippet = snip
        let rows = CodeView.rows(for: edit)
        check(rows.map(\.kind) == [.context, .context, .removed, .added, .added, .context, .context], "row kinds in file order")
        check(rows.map(\.number) == [2, 3, 4, 4, 5, 6, 7], "line numbers from the file")
        check(CodeView.fit(rows, max: 4).map(\.kind) == [.removed, .added, .added, .context], "far context goes first")

        let write = CodeEdit(isWrite: true, path: "/work/shop/new.ts", file: "new.ts", removed: "", added: "a\nb")
        check(CodeView.rows(for: write).map(\.number) == [1, 2], "a new file counts from line 1")

        // An edit's rows wait for the lines around it, so they never shift
        var w = CodeSession(project: "shop", root: "/work/shop")
        let editInput = { (added: String) -> [String: Any] in
            ["file_path": "/work/shop/a.ts", "old_string": "x", "new_string": added]
        }
        let around = CodeSnippet(start: 1, lines: ["a", "y"], at: 1, len: 1)
        w.toolStarted(tool: "Edit", input: editInput("y"), cwd: "/work/shop")
        w.awaitSnippet()
        check(w.edit?.pending == true && w.hasContent, "an edit waits for its lines")
        let first = w.edit!
        w.snippetRead(around, for: first)
        check(w.edit?.pending == false && w.edit?.snippet == around, "its lines arrive with it")
        w.toolStarted(tool: "Edit", input: editInput("z"), cwd: "/work/shop")
        w.awaitSnippet()
        w.snippetRead(around, for: first)
        check(w.edit?.pending == true && w.edit?.snippet == nil, "an answer for an older edit is dropped")
        w.snippetRead(nil, for: w.edit!)
        check(w.edit?.pending == false, "lines that cannot be read let it show alone")
        w.toolStarted(tool: "Edit", input: editInput("q"), cwd: "/work/shop")
        w.awaitSnippet()
        w.toolFinished(tool: "Edit", response: nil, failed: true, error: "no match")
        check(w.edit?.pending == false, "a failed edit shows alone")
        w.toolStarted(tool: "Edit", input: editInput("r"), cwd: "/work/shop")
        w.awaitSnippet()
        w.endTurn()
        check(w.edit?.pending == false, "the end of the turn lets an interrupted edit show")

        // File reads stay inside the session folder
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("code-session-\(getpid())")
        try? FileManager.default.removeItem(at: dir)
        try! FileManager.default.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("src/a.ts")
        try! text.write(to: file, atomically: true, encoding: .utf8)
        check(CodeView.readSnippet(path: file.path, root: dir.path, find: "return X")?.start == 2, "a file in the folder is read")
        check(CodeView.readSnippet(path: file.path, root: dir.appendingPathComponent("other").path, find: "return X") == nil,
              "a file outside the folder is not")
        let link = dir.appendingPathComponent("src/link.ts")
        try? FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/etc/hosts")
        check(CodeView.readSnippet(path: link.path, root: dir.path, find: "localhost") == nil, "a link out of the folder is not")
        try? FileManager.default.removeItem(at: dir)

        if failures > 0 { print("\(failures) failure(s)"); exit(1) }
        print("All code view tests passed")
    }
}
