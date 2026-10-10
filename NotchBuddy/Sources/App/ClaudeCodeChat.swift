import Foundation

// MARK: - Claude Code as a chat provider
// Each turn runs the user's own `claude -p`, so the chat has their sign-in, MCP
// servers, skills, CLAUDE.md and hooks. Coucou holds no key and talks to nobody new.
//
// A conversation is one Claude Code session, resumed turn after turn. It runs in
// Coucou's own folder (claude-chat in Application Support) unless the user picks
// a project folder, so nothing lands in the home folder. COUCOU_CHAT=1 marks its
// hook events: the island shows its permission requests and nothing else.
// Same arguments and behaviour as windows/src-tauri/src/claude_code.rs.

enum ClaudeCodeChat {
    /// No --model: whatever the user's Claude Code uses.
    static let defaultModel = "default"
    /// What `claude --model` takes as aliases (claude --help).
    static let models = ["fable", "opus", "sonnet", "haiku"]
    /// What `claude --effort` takes (claude --help); "" is Claude Code's own.
    static let efforts = ["low", "medium", "high", "xhigh", "max"]

    static var modelList: [(id: String, label: String)] {
        var list: [(id: String, label: String)] = [(id: defaultModel, label: String(localized: "Claude Code's default"))]
        for m in models { list.append((id: m, label: m.capitalized)) }
        return list
    }

    /// The model button's text: its model and effort.
    static func label(model: String, effort: String) -> String {
        let name = model == defaultModel ? "Claude Code" : model
        return effort.isEmpty ? name : "\(name) · \(effort)"
    }

    // MARK: Command line

    /// The arguments after `claude`. The question goes on stdin. Only known
    /// models and efforts reach the command line.
    static func arguments(systemPrompt: String, model: String, effort: String,
                          resume: String?, extraDir: String?) -> [String] {
        var a = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                 "--append-system-prompt", systemPrompt]
        if model != defaultModel && models.contains(model) { a += ["--model", model] }
        if efforts.contains(effort) { a += ["--effort", effort] }
        if let resume { a += ["--resume", resume] }
        // A dropped file lives outside the working folder.
        if let extraDir { a += ["--add-dir", extraDir] }
        return a
    }

    /// The question, with what Claude Code does not know yet: the dropped file or
    /// window on the first turn, or the turns another provider answered before.
    static func question(first: Bool, resuming: Bool, earlier: [(user: Bool, text: String)],
                         context: String?, query: String) -> String {
        var text = ""
        if !first && !resuming {
            text += "Earlier in this conversation:\n"
            for m in earlier { text += "\(m.user ? "User" : "Assistant"): \(m.text)\n" }
            text += "\n"
        }
        if first, let context { text += context + "\n\n" }
        return text + query
    }

    // MARK: Stream

    enum Line: Equatable {
        case session(String)
        /// Text to add to the answer.
        case text(String)
        /// A new text block after something else (a tool call): a paragraph break.
        case block
        case done(error: String?, result: String)
        case other
    }

    static func parse(_ line: String) -> Line {
        guard let data = line.data(using: .utf8),
              let v = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .other }
        let subtype = v["subtype"] as? String
        switch v["type"] as? String ?? "" {
        case "system" where subtype == "init":
            return (v["session_id"] as? String).map { .session($0) } ?? .other
        case "stream_event":
            let event = v["event"] as? [String: Any] ?? [:]
            switch event["type"] as? String ?? "" {
            case "content_block_delta":
                let delta = event["delta"] as? [String: Any] ?? [:]
                guard delta["type"] as? String == "text_delta" else { return .other }
                return .text(delta["text"] as? String ?? "")
            case "content_block_start":
                let block = event["content_block"] as? [String: Any] ?? [:]
                return block["type"] as? String == "text" ? .block : .other
            default:
                return .other
            }
        case "result":
            let result = v["result"] as? String ?? ""
            let failed = (v["is_error"] as? Bool ?? false) || subtype != "success"
            let error = failed ? (result.isEmpty ? (subtype ?? "error") : result) : nil
            return .done(error: error, result: result)
        default:
            return .other
        }
    }

    // MARK: Finding claude (as upstream PR #12 does)

    /// PATH as the user's login shell sees it: an app started from Finder gets a
    /// bare PATH, and `claude` may be a node script needing `node` on PATH too.
    /// Computed once, on first use, off the main thread.
    static let searchPath: String = {
        let home = NSHomeDirectory()
        let fallback = [
            "\(home)/.local/bin", "\(home)/.claude/local", "\(home)/.npm-global/bin",
            "\(home)/.bun/bin", "\(home)/.volta/bin",
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        var dirs: [String] = []
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // -i as well as -l: many setups add ~/.local/bin in .zshrc. Markers keep rc chatter out.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-ilc", "printf '__CC_PATH__%s__CC_PATH__' \"$PATH\""]
        p.currentDirectoryURL = URL(fileURLWithPath: home)
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            let killer = DispatchWorkItem { p.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: killer)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            killer.cancel()
            let parts = (String(data: data, encoding: .utf8) ?? "").components(separatedBy: "__CC_PATH__")
            if parts.count >= 3 { dirs = parts[1].split(separator: ":").map(String.init) }
        }
        for d in fallback where !dirs.contains(d) { dirs.append(d) }
        return dirs.joined(separator: ":")
    }()

    static func locate() -> String? {
        searchPath.split(separator: ":").map { "\($0)/claude" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The folder Claude Code works in: the one picked in Settings, else Coucou's own.
    static func workDir(picked: String, supportDir: URL) throws -> URL {
        let picked = picked.trimmingCharacters(in: .whitespacesAndNewlines)
        if !picked.isEmpty {
            var isDir: ObjCBool = false
            guard picked.hasPrefix("/"), FileManager.default.fileExists(atPath: picked, isDirectory: &isDir), isDir.boolValue else {
                throw failure(String(format: String(localized: "%@ is not a folder."), picked))
            }
            return URL(fileURLWithPath: picked)
        }
        let dir = supportDir.appendingPathComponent("claude-chat")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700 as NSNumber], ofItemAtPath: dir.path)
        return dir
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "ClaudeCodeChat", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: Running a turn

    /// The turn running now, so New chat can stop it.
    private nonisolated(unsafe) static var running: Process?
    private nonisolated(unsafe) static var cancelled = false

    /// Stops the turn that is running, if any: SIGTERM to that `claude` only, so
    /// it can end its MCP servers.
    static func cancel() {
        guard let p = running, p.isRunning else { return }
        cancelled = true
        p.terminate()
    }

    /// Runs one turn. `onText` gets the answer so far. Returns the answer and the
    /// session it belongs to; nil when the turn was stopped by New chat.
    static func run(executable: String, arguments: [String], directory: URL, prompt: String,
                    resume: String?, onText: @MainActor @escaping (String) -> Void) async throws -> (answer: String, session: String?)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.currentDirectoryURL = directory
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath
        env["COUCOU_CHAT"] = "1"
        // Nothing that would make Coucou's hooks take this run for an editor session.
        for k in ["TERM_PROGRAM", "TERM_PROGRAM_VERSION", "VSCODE_PID", "CLAUDECODE"] { env[k] = nil }
        p.environment = env
        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors
        // Drained as it comes, so a chatty stderr cannot fill its pipe and stall the turn.
        let stderrBox = StderrBox()
        errors.fileHandleForReading.readabilityHandler = { h in stderrBox.append(h.availableData) }

        do { try p.run() } catch { throw failure("\(executable): \(error.localizedDescription)") }
        cancelled = false
        running = p
        input.fileHandleForWriting.write(Data(prompt.utf8))
        try? input.fileHandleForWriting.close()

        var session = resume
        var answer = ""
        var done: (error: String?, result: String)? = nil
        var lastUpdate = Date.distantPast
        for try await line in output.fileHandleForReading.bytes.lines {
            switch parse(line) {
            case .session(let id): session = id
            case .text(let more):
                answer += more
                // At most 15 redraws a second, like the other streaming providers.
                if Date().timeIntervalSince(lastUpdate) >= 1.0 / 15.0 {
                    lastUpdate = Date()
                    let visible = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                    await MainActor.run { onText(visible) }
                }
            case .block where !answer.isEmpty: answer += "\n\n"
            case .done(let error, let result): done = (error, result)
            default: break
            }
        }
        p.waitUntilExit()
        errors.fileHandleForReading.readabilityHandler = nil
        running = nil
        if cancelled { return nil }

        guard let done else {
            // No result line: Claude Code's own words on stderr, as they are.
            let last = stderrBox.text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty }
            throw failure(last ?? String(localized: "No response text."))
        }
        if let error = done.error { throw failure(error) }
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let final = text.isEmpty ? done.result.trimmingCharacters(in: .whitespacesAndNewlines) : text
        guard !final.isEmpty else { throw failure(String(localized: "No response text.")) }
        await MainActor.run { onText(final) }
        return (final, session)
    }
}

private final class StderrBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ more: Data) { lock.withLock { data.append(more) } }
    var text: String { lock.withLock { String(data: data, encoding: .utf8) ?? "" } }
}
