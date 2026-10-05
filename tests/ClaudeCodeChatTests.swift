import Foundation

// ClaudeCodeChat only needs the support folder from the app.
enum HookServer {
    static var supportDir: URL { FileManager.default.temporaryDirectory.appendingPathComponent("coucou-chat-tests") }
}

@main
enum ClaudeCodeChatTests {

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

    static let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("coucou-fake-claude-\(UUID().uuidString)")

    /// A stand-in `claude` that saves its arguments and stdin, prints `output`, then exits.
    static func fakeClaude(_ name: String, output: [String], exitCode: Int = 0) -> URL {
        let url = dir.appendingPathComponent(name)
        let lines = output.map { "printf '%s\\n' '\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
        let script = """
        #!/bin/bash
        printf '%s\\n' "$@" > "\(dir.path)/\(name).args"
        cat > "\(dir.path)/\(name).stdin"
        \(lines.joined(separator: "\n"))
        exit \(exitCode)
        """
        try! script.write(to: url, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    static func read(_ name: String) -> String {
        (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    static func delta(_ text: String) -> String {
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(text)"}}}"#
    }

    static func blockStart(_ type: String) -> String {
        #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"\#(type)"}}}"#
    }

    @MainActor
    static func send(_ exe: URL?, resume: Bool = false,
                     onText: (String) -> Void = { _ in }) async -> Result<String, Error> {
        do {
            let text = try await ClaudeCodeChat.send(
                prompt: "-x what is up?", sessionId: "abc", resume: resume, model: "haiku",
                systemPrompt: "You are Mochi.",
                executable: exe, onText: onText)
            return .success(text)
        } catch {
            return .failure(error)
        }
    }

    @MainActor
    static func main() async {
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // ── streaming answer with a web search in the middle ───────────────────
        print("ClaudeCodeChat.send — streamed answer")
        let ok = fakeClaude("ok", output: [
            #"{"type":"system","subtype":"init","session_id":"abc"}"#,
            "a warning on stderr",
            blockStart("text"), delta("Hel"), delta("lo"),
            blockStart("server_tool_use"),
            blockStart("text"), delta("again"),
            #"{"type":"result","subtype":"success","is_error":false,"result":"again"}"#,
        ])
        var seen: [String] = []
        let r1 = await send(ok) { seen.append($0) }
        check("final keeps text from before the search", (try? r1.get()) ?? "", "Hello\n\nagain")
        check("onText streams the growing answer", seen.joined(separator: "|"), "Hel|Hello|Hello\n\nagain")
        check("prompt goes through stdin", read("ok.stdin"), "-x what is up?")
        let args1 = read("ok.args").split(separator: "\n").map(String.init)
        checkTrue("first turn starts the session", args1.contains("--session-id") && !args1.contains("--resume"))
        checkTrue("hooks are kept out with --safe-mode", args1.contains("--safe-mode"))
        checkTrue("web tools only", args1.contains("WebSearch,WebFetch"))
        checkTrue("no file access, so a web page can't make it leak local files",
                  !args1.contains { $0.contains("Read") || $0 == "--add-dir" })

        // ── resume ─────────────────────────────────────────────────────────────
        print("ClaudeCodeChat.send — later turns")
        _ = await send(ok, resume: true)
        let args2 = read("ok.args").split(separator: "\n").map(String.init)
        checkTrue("later turns resume the session", args2.contains("--resume") && !args2.contains("--session-id"))

        // ── errors ─────────────────────────────────────────────────────────────
        print("ClaudeCodeChat.send — errors")
        let loggedOut = fakeClaude("loggedout", output: [
            #"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login"}"#,
        ])
        if case .failure(let e) = await send(loggedOut) {
            check("is_error result becomes the message", e.localizedDescription, "Not logged in · Please run /login")
        } else {
            checkTrue("is_error result throws", false)
        }

        let crash = fakeClaude("crash", output: ["error: unknown option '--safe-mode'"], exitCode: 1)
        if case .failure(let e) = await send(crash) {
            check("a crash shows the CLI's own line", e.localizedDescription, "error: unknown option '--safe-mode'")
        } else {
            checkTrue("a crash throws", false)
        }

        if case .failure(let e) = await send(nil) {
            checkTrue("missing CLI says so", e.localizedDescription.hasPrefix("Claude Code isn't installed"))
        } else {
            checkTrue("missing CLI throws", false)
        }

        // ── past chats ─────────────────────────────────────────────────────────
        print("ClaudeCodeChat — transcripts")
        let lines = [
            #"{"type":"queue-operation","operation":"enqueue"}"#,
            #"{"type":"user","message":{"role":"user","content":"Context — App: Safari, Window: Docs\n\nFile: x\n\nWhat is this?"}}"#,
            #"{"type":"attachment","attachment":{}}"#,
            #"{"type":"assistant","message":{"role":"assistant","model":"claude-sonnet","content":[{"type":"text","text":"Let me look."}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","model":"claude-sonnet","content":[{"type":"tool_use","name":"WebFetch"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"<html>"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","model":"claude-sonnet","content":[{"type":"text","text":"It is a doc."}]}}"#,
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":"caveat"}}"#,
            #"{"type":"user","isSidechain":true,"message":{"role":"user","content":"sub agent"}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Thanks"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"API Error"}]}}"#,
            #"{"type":"some-future-record","message":"x"}"#,
            "not json",
        ]
        let turns = ClaudeCodeChat.transcript(Data(lines.joined(separator: "\n").utf8))
        check("typed questions and answers, one bubble per turn",
              turns.map { ($0.user ? "U:" : "A:") + $0.text }.joined(separator: "|"),
              "U:What is this?|A:Let me look.\n\nIt is a doc.|U:Thanks")

        let chats = dir.appendingPathComponent("transcripts")
        try! FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let older = "11111111-1111-4111-8111-111111111111", newer = "22222222-2222-4222-8222-222222222222"
        func save(_ name: String, _ lines: [String], age: TimeInterval) {
            let url = chats.appendingPathComponent(name)
            try! lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        save(older + ".jsonl", lines, age: 3600)
        save(newer + ".jsonl", [#"{"type":"queue-operation"}"#], age: 60)
        save("not-a-session.jsonl", lines, age: 0)
        save(older + ".json", lines, age: 0)

        let sessions = ClaudeCodeChat.sessions(in: chats)
        check("newest first, only session transcripts", sessions.map(\.id).joined(separator: ","), newer + "," + older)
        check("title is the first typed question", sessions.last?.title ?? "", "What is this?")
        check("no question yet", sessions.first?.title ?? "", "Untitled chat")
        check("limit", "\(ClaudeCodeChat.sessions(in: chats, limit: 1).count)", "1")
        check("messages of a session", "\(ClaudeCodeChat.messages(of: older, in: chats)?.count ?? -1)", "3")
        checkTrue("an ID can't leave the folder", ClaudeCodeChat.messages(of: "../\(older)", in: chats) == nil)

        try? ClaudeCodeChat.delete(older, in: chats)
        check("delete removes the transcript", ClaudeCodeChat.sessions(in: chats).map(\.id).joined(), newer)
        try? ClaudeCodeChat.delete("../not-a-session", in: chats)
        checkTrue("delete ignores anything that isn't a session ID",
                  FileManager.default.fileExists(atPath: chats.appendingPathComponent("not-a-session.jsonl").path))

        try? FileManager.default.removeItem(at: dir)

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
