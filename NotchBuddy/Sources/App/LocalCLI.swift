import Foundation

// MARK: - Chat engine
// What answers in the notch chat: one of the AI CLIs installed on this Mac (using
// the login the user already has), or the Anthropic API with a key from Settings.

enum ChatEngine: String, CaseIterable, Identifiable, Sendable {
    case claude, codex, gemini, api

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex:  return "Codex"
        case .gemini: return "Gemini CLI"
        case .api:    return "Anthropic API"
        }
    }

    /// Short name for the overview status badge.
    var badge: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        case .gemini: return "Gemini"
        case .api:    return "API"
        }
    }

    /// Executable name looked up on PATH; nil for the API.
    var command: String? {
        switch self {
        case .claude: return "claude"
        case .codex:  return "codex"
        case .gemini: return "gemini"
        case .api:    return nil
        }
    }

    static var cliEngines: [ChatEngine] { allCases.filter { $0.command != nil } }
}

struct CLIInfo: Sendable, Equatable {
    let path: String
    let version: String?
}

struct CLIResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: String
    let timedOut: Bool
}

// MARK: - Detection + process runner

enum LocalCLI {

    /// PATH as the user's login shell sees it. Apps launched from Finder get a bare
    /// PATH, and these CLIs usually live in ~/.local/bin, Homebrew or an npm prefix —
    /// and they're node scripts, so `node` has to be reachable too.
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
        // -i as well as -l: many setups add ~/.local/bin in .zshrc, not .zprofile.
        // Markers keep rc-file chatter ("Restored session…") out of the result.
        let r = runBlocking(shell, ["-ilc", "printf '__CC_PATH__%s__CC_PATH__' \"$PATH\""],
                            cwd: URL(fileURLWithPath: home), stdin: nil, env: nil, timeout: 5)
        if let out = String(data: r.stdout, encoding: .utf8) {
            let parts = out.components(separatedBy: "__CC_PATH__")
            if parts.count >= 3 { dirs = parts[1].split(separator: ":").map(String.init) }
        }
        for d in fallback where !dirs.contains(d) { dirs.append(d) }
        return dirs.joined(separator: ":")
    }()

    /// Absolute path of `command` on the login PATH, or nil when not installed.
    static func locate(_ command: String) -> String? {
        let fm = FileManager.default
        for dir in searchPath.split(separator: ":") {
            let p = "\(dir)/\(command)"
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Finds every supported CLI and asks each for its version. Blocking — call off main.
    static func detectAll() -> [ChatEngine: CLIInfo] {
        var found: [ChatEngine: CLIInfo] = [:]
        for engine in ChatEngine.cliEngines {
            guard let cmd = engine.command, let path = locate(cmd) else { continue }
            let r = runBlocking(path, ["--version"], cwd: URL(fileURLWithPath: NSHomeDirectory()),
                                stdin: nil, env: nil, timeout: 10)
            let version = String(data: r.stdout, encoding: .utf8)?
                .split(separator: "\n").first
                .map { $0.trimmingCharacters(in: .whitespaces) }
            found[engine] = CLIInfo(path: path, version: (version?.isEmpty ?? true) ? nil : version)
        }
        return found
    }

    static func run(_ executable: String, _ args: [String], cwd: URL, stdin: String?,
                    timeout: TimeInterval) async -> CLIResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: runBlocking(executable, args, cwd: cwd, stdin: stdin,
                                                   env: childEnvironment(), timeout: timeout))
            }
        }
    }

    /// Environment for the chat CLIs: the login PATH, and nothing that would make
    /// Coucou's own hooks mistake this run for a VS Code session.
    private static func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath
        for k in ["TERM_PROGRAM", "TERM_PROGRAM_VERSION", "VSCODE_PID", "CLAUDECODE"] { env[k] = nil }
        env["NO_COLOR"] = "1"
        return env
    }

    private static func runBlocking(_ executable: String, _ args: [String], cwd: URL,
                                    stdin: String?, env: [String: String]?,
                                    timeout: TimeInterval) -> CLIResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.currentDirectoryURL = cwd
        if let env { p.environment = env }

        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let inPipe: Pipe? = stdin == nil ? nil : Pipe()
        p.standardInput = inPipe ?? FileHandle.nullDevice

        do { try p.run() } catch {
            return CLIResult(status: -1, stdout: Data(), stderr: error.localizedDescription, timedOut: false)
        }

        if let inPipe, let stdin {
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        }

        let timedOut = TimeoutFlag()
        let killer = DispatchWorkItem {
            timedOut.set()
            p.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

        // Drain both pipes concurrently so a chatty stderr can't fill its buffer and stall.
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errBox.data = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        killer.cancel()

        return CLIResult(status: p.terminationStatus, stdout: outData,
                         stderr: String(data: errBox.data, encoding: .utf8) ?? "",
                         timedOut: timedOut.value)
    }
}

private final class DataBox: @unchecked Sendable { var data = Data() }

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}

// MARK: - Chat through a local CLI

@MainActor
final class LocalCLIChat {
    static let shared = LocalCLIChat()

    /// Session to resume per engine, so follow-ups keep the conversation.
    private var sessions: [ChatEngine: String] = [:]
    private(set) var isBusy = false

    /// Dedicated folder so chat sessions don't land in (or read from) a real project.
    private var workDir: URL {
        let dir = HookServer.supportDir.appendingPathComponent("chat")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let instructions = """
    You are Mochi, a small assistant living in the notch of the user's Mac. \
    Answer in the user's language, clearly and completely. \
    Plain text only: no markdown (no **, no #, no bullet dashes), just line breaks. \
    Do not create, edit or delete files.
    """

    func reset() { sessions = [:] }

    struct Reply { let text: String; let isError: Bool }

    func send(engine: ChatEngine, query: String, context: PromptContext?) async -> Reply {
        guard let cmd = engine.command else { return Reply(text: "Not a CLI engine.", isError: true) }
        guard !isBusy else { return Reply(text: "Still answering the previous message…", isError: true) }
        isBusy = true
        defer { isBusy = false }

        let path = await Task.detached { LocalCLI.locate(cmd) }.value
        guard let path else {
            return Reply(text: "\(engine.label) isn't installed. Pick another engine in Settings.", isError: true)
        }

        let resumeId = sessions[engine]
        let isFirst = resumeId == nil

        // Context goes in with the first message only, like the API chat.
        var prompt = ""
        var fileURL: URL?
        if isFirst, let context {
            switch context {
            case .window(let app, let title, let url):
                prompt += "Context — App: \(app), Window: \(title)"
                if let url { prompt += ", URL: \(url)" }
                prompt += "\n\n"
            case .file(let name, let url):
                fileURL = url
                if let url {
                    prompt += "The user attached a file: \(url.path) — read it to answer.\n\n"
                } else {
                    prompt += "File: \(name)\n\n"
                }
            }
        }
        if isFirst && engine != .claude { prompt += instructions + "\n\n" }
        prompt += query

        var args: [String]
        switch engine {
        case .claude:
            args = ["-p", "--output-format", "json",
                    "--append-system-prompt", instructions,
                    "--allowedTools", "WebSearch,WebFetch,Read"]
            if let resumeId { args += ["--resume", resumeId] }
            if let dir = fileURL?.deletingLastPathComponent().path { args += ["--add-dir", dir] }
        case .codex:
            args = ["exec"]
            if resumeId != nil { args += ["resume"] }
            args += ["--json", "--skip-git-repo-check", "-c", "sandbox_mode=\"read-only\""]
            if let f = fileURL, ["png", "jpg", "jpeg", "gif", "webp"].contains(f.pathExtension.lowercased()) {
                args += ["-i", f.path]
            }
            if let resumeId { args += [resumeId] }
            args += ["-"]
        case .gemini:
            args = ["--output-format", "json"]
            if resumeId != nil { args += ["--resume", "latest"] }
            if let dir = fileURL?.deletingLastPathComponent().path { args += ["--include-directories", dir] }
        case .api:
            return Reply(text: "Not a CLI engine.", isError: true)
        }

        let r = await LocalCLI.run(path, args, cwd: workDir, stdin: prompt, timeout: 300)
        if r.timedOut {
            return Reply(text: "\(engine.label) took too long to answer.", isError: true)
        }

        let parsed = parse(engine: engine, stdout: r.stdout)
        if let sid = parsed.sessionId { sessions[engine] = sid }

        if let text = parsed.text, !text.isEmpty, !parsed.isError {
            return Reply(text: text, isError: false)
        }
        let detail = parsed.text
            ?? r.stderr.split(separator: "\n").last.map(String.init)
            ?? "exit code \(r.status)"
        return Reply(text: "\(engine.label): \(detail)", isError: true)
    }

    private struct Parsed { var text: String?; var sessionId: String?; var isError = false }

    private func parse(engine: ChatEngine, stdout: Data) -> Parsed {
        let raw = String(data: stdout, encoding: .utf8) ?? ""
        switch engine {
        case .claude:
            // {"result": "...", "is_error": false, "session_id": "..."}
            guard let obj = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any] else {
                return Parsed(text: nilIfEmpty(raw))
            }
            return Parsed(text: obj["result"] as? String,
                          sessionId: obj["session_id"] as? String,
                          isError: obj["is_error"] as? Bool ?? false)

        case .codex:
            // JSONL events: thread.started {thread_id}, item.completed {item: agent_message}, error / turn.failed
            var p = Parsed()
            for line in raw.split(separator: "\n") {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let type = obj["type"] as? String else { continue }
                switch type {
                case "thread.started":
                    p.sessionId = obj["thread_id"] as? String
                case "item.completed":
                    if let item = obj["item"] as? [String: Any],
                       item["type"] as? String == "agent_message",
                       let text = item["text"] as? String {
                        p.text = text
                    }
                case "error":
                    p.isError = true; p.text = obj["message"] as? String ?? p.text
                case "turn.failed":
                    p.isError = true
                    p.text = (obj["error"] as? [String: Any])?["message"] as? String ?? p.text
                default: break
                }
            }
            return p

        case .gemini:
            // {"response": "...", "stats": {...}} or {"error": {"message": "..."}}
            // Older versions ignore --output-format and print plain text.
            guard let start = raw.firstIndex(of: "{"),
                  let obj = try? JSONSerialization.jsonObject(with: Data(raw[start...].utf8)) as? [String: Any] else {
                return Parsed(text: nilIfEmpty(raw), sessionId: raw.isEmpty ? nil : "latest")
            }
            if let err = obj["error"] as? [String: Any] {
                return Parsed(text: err["message"] as? String, isError: true)
            }
            return Parsed(text: obj["response"] as? String, sessionId: "latest")

        case .api:
            return Parsed()
        }
    }

    private func nilIfEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
