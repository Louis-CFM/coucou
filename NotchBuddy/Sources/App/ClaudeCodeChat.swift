import Foundation

enum ClaudeCodeChatError: LocalizedError {
    case notInstalled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "Claude Code isn't installed. Install it, log in once in a terminal, then ask again."
        case .failed(let message): return message
        }
    }
}

/// Chat through the user's own `claude` CLI, so a Claude Pro or Max plan works without an API key.
enum ClaudeCodeChat {
    static let models: [(id: String, label: String)] = [
        (id: "sonnet", label: "Sonnet"),
        (id: "opus",   label: "Opus"),
        (id: "haiku",  label: "Haiku"),
    ]

    /// Web only. No file access: a fetched page could otherwise make the chat read a local
    /// secret and send it out. Attached files go inline in the prompt instead.
    private static let tools = "WebSearch,WebFetch"

    /// A GUI app doesn't get the shell's PATH, so look where the installers put `claude`.
    static func executableURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                          "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Sessions live in their own folder so they never mix with the user's projects.
    private static var workingDirectory: URL {
        let dir = HookServer.supportDir.appendingPathComponent("chat")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Runs one turn and streams the visible answer to `onText`. Returns the final answer.
    /// `--safe-mode` keeps the user's hooks (Coucou's own included) out of the chat.
    @MainActor
    static func send(prompt: String, sessionId: String, resume: Bool, model: String,
                     systemPrompt: String,
                     executable: URL? = executableURL(),
                     onText: (String) -> Void) async throws -> String {
        guard let exe = executable else { throw ClaudeCodeChatError.notInstalled }

        var args = ["-p", "--safe-mode", "--output-format", "stream-json", "--verbose",
                    "--include-partial-messages", "--model", model, "--system-prompt", systemPrompt,
                    "--tools", tools, "--allowedTools", tools]
        args += resume ? ["--resume", sessionId] : ["--session-id", sessionId]

        let process = Process()
        process.executableURL = exe
        process.arguments = args
        process.currentDirectoryURL = workingDirectory
        var env = ProcessInfo.processInfo.environment
        // npm installs need `node` next to them on PATH.
        env["PATH"] = [exe.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin",
                       env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        process.environment = env

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output   // non-JSON lines are the CLI's own errors

        let exit = AsyncStream<Int32> { cont in
            process.terminationHandler = { cont.yield($0.terminationStatus); cont.finish() }
        }
        try process.run()
        // The prompt goes through stdin so text starting with "-" is never read as a flag.
        try input.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
        try input.fileHandleForWriting.close()

        // A turn with web searches can take minutes; never leave Mochi thinking forever.
        let watchdog = Task { @MainActor in
            try await Task.sleep(for: .seconds(300))
            if process.isRunning { process.terminate() }
        }
        defer { watchdog.cancel() }

        var visible = ""
        var result: String?
        var resultIsError = false
        var otherLines: [String] = []
        for try await line in output.fileHandleForReading.bytes.lines {
            guard let json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
                otherLines.append(line)
                continue
            }
            switch json["type"] as? String {
            case "stream_event":
                guard let event = json["event"] as? [String: Any] else { break }
                if event["type"] as? String == "content_block_start",
                   (event["content_block"] as? [String: Any])?["type"] as? String == "text",
                   !visible.isEmpty {
                    visible += "\n\n"   // text resumes after a web search
                }
                if event["type"] as? String == "content_block_delta",
                   let delta = event["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let text = delta["text"] as? String {
                    visible += text
                    onText(visible)
                }
            case "result":
                result = json["result"] as? String
                resultIsError = json["is_error"] as? Bool ?? false
            default:
                break
            }
        }

        var status: Int32 = -1
        for await code in exit { status = code }
        if resultIsError {
            throw ClaudeCodeChatError.failed(result ?? "Claude Code returned an error.")
        }
        // `result` holds only the last text block; `visible` keeps the text before a web search too.
        if !visible.isEmpty { return visible }
        if let result, !result.isEmpty { return result }
        let detail = otherLines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        throw ClaudeCodeChatError.failed(detail ?? "Claude Code stopped (exit \(status)).")
    }
}

struct ClaudeCodeChatSession: Identifiable, Equatable {
    let id: String
    let title: String
    let updated: Date
}

// Past chats, read from the CLI's own transcripts. Their format is internal to Claude Code,
// so parsing skips anything it doesn't know; `--resume` works even when nothing parses.
extension ClaudeCodeChat {
    /// One `<session id>.jsonl` per chat, in the folder the CLI names after the chat's directory.
    static var transcriptDirectory: URL {
        let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let folder = String(workingDirectory.path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        return config.appendingPathComponent("projects").appendingPathComponent(folder)
    }

    /// Newest first. Titles come from the first question, so only the head of each file is read.
    static func sessions(in dir: URL = transcriptDirectory, limit: Int = 20) -> [ClaudeCodeChatSession] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { $0.pathExtension == "jsonl" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { url, updated in
                let head = (try? FileHandle(forReadingFrom: url)).flatMap { try? $0.read(upToCount: 256 * 1024) } ?? Data()
                let title = transcript(head).first { $0.user }?.text
                    .split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                return ClaudeCodeChatSession(id: url.deletingPathExtension().lastPathComponent,
                                             title: title.isEmpty ? "Untitled chat" : title,
                                             updated: updated)
            }
    }

    /// Nil when the chat is gone, e.g. deleted or cleaned up by Claude Code.
    static func messages(of sessionId: String, in dir: URL = transcriptDirectory) -> [(user: Bool, text: String)]? {
        guard let url = transcriptURL(sessionId, in: dir), let data = try? Data(contentsOf: url) else { return nil }
        return transcript(data)
    }

    static func delete(_ sessionId: String, in dir: URL = transcriptDirectory) throws {
        guard let url = transcriptURL(sessionId, in: dir) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Only UUID names, so an ID can never point outside the transcript folder.
    private static func transcriptURL(_ sessionId: String, in dir: URL) -> URL? {
        guard UUID(uuidString: sessionId) != nil else { return nil }
        return dir.appendingPathComponent(sessionId + ".jsonl")
    }

    /// The chat as it was shown: typed questions and Mohinur's text, one bubble per turn.
    static func transcript(_ data: Data) -> [(user: Bool, text: String)] {
        var turns: [(user: Bool, text: String)] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let message = record["message"] as? [String: Any],
                  record["isSidechain"] as? Bool != true, record["isMeta"] as? Bool != true,
                  record["isCompactSummary"] as? Bool != true, record["isApiErrorMessage"] as? Bool != true
            else { continue }
            let blocks = message["content"] as? [[String: Any]] ?? []
            let blockText = blocks.filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }.joined(separator: "\n\n")
            switch record["type"] as? String {
            case "user":
                // Tool results come back as user records too; they were never typed.
                guard !blocks.contains(where: { $0["type"] as? String == "tool_result" }) else { continue }
                let text = typedQuestion(message["content"] as? String ?? blockText)
                if !text.isEmpty { turns.append((true, text)) }
            case "assistant":
                guard !blockText.isEmpty, message["model"] as? String != "<synthetic>" else { continue }
                if let last = turns.last, !last.user {
                    turns[turns.count - 1].text += "\n\n" + blockText   // text resumes after a web search
                } else {
                    turns.append((false, blockText))
                }
            default:
                continue
            }
        }
        return turns
    }

    /// The first prompt carries the window or file context ahead of the question; the field is one line.
    private static func typedQuestion(_ prompt: String) -> String {
        guard prompt.hasPrefix("Context — ") || prompt.hasPrefix("File: "),
              let split = prompt.range(of: "\n\n", options: .backwards) else {
            return prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return prompt[split.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
