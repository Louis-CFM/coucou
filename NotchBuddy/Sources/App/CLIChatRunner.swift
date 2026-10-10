#if !APPSTORE
import Foundation

enum CLIChatError: Error, Equatable {
    case notInstalled
    case notSignedIn
    case failed(String)
}

/// Runs a signed-in coding-agent CLI as a plain chat backend. The tool does its own sign-in:
/// Coucou never reads its Keychain item, its token files or its settings.
enum CLIChatRunner {

    private static let replyTimeout: TimeInterval = 300
    // Copilot checks with GitHub first: about 5 s on a normal connection.
    private static let statusTimeout: TimeInterval = 25
    private static let maxStderr = 2000

    // MARK: Finding

    static func locate(_ tool: CLIChatTool) -> String? {
        let home = NSHomeDirectory()
        let nvm = (try? FileManager.default.contentsOfDirectory(atPath: "\(home)/.nvm/versions/node")) ?? []
        let extensions = (try? FileManager.default.contentsOfDirectory(atPath: "\(home)/.vscode/extensions")) ?? []
        let candidates = CLIChatTools.binaryCandidates(tool.binary, home: home, nodeVersions: nvm.sorted().reversed())
            + CLIChatTools.extensionBinaryCandidates(tool, home: home, extensionFolders: extensions)
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// nil when the tool is not installed or does not answer.
    static func authStatus(_ tool: CLIChatTool) async -> CLIAuthStatus? {
        guard let path = locate(tool) else { return nil }
        guard let output = await run(path, CLIChatTools.statusArguments(tool), timeout: statusTimeout,
                                     mergeStderr: CLIChatTools.statusNeedsStderr(tool)) else { return nil }
        return CLIChatTools.parseStatus(tool, output: output)
    }

    // MARK: Chat

    /// Asks `tool` and calls `onText` with the reply so far. Returns the final reply.
    static func chat(_ tool: CLIChatTool, model: String, systemPrompt: String, prompt: String,
                     onText: @MainActor @escaping (String) -> Void) async throws -> String {
        guard let path = locate(tool) else { throw CLIChatError.notInstalled }
        let fullPrompt = CLIChatTools.promptInput(tool, systemPrompt: systemPrompt, transcript: prompt)
        guard let arguments = CLIChatTools.chatArguments(tool, model: model, systemPrompt: systemPrompt, prompt: fullPrompt)
        else { throw CLIChatError.failed("\(tool.name) does not offer the model “\(model)”.") }

        let process = makeProcess(path, arguments, extraEnvironment: CLIChatTools.environment(tool))
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch { throw CLIChatError.failed("Could not start \(tool.name).") }

        // The prompt goes over stdin where the tool allows: a long conversation does not fit comfortably in an argument.
        if !CLIChatTools.sendsPromptAsArgument(tool) { stdin.fileHandleForWriting.write(Data(fullPrompt.utf8)) }
        try? stdin.fileHandleForWriting.close()

        let watchdog = Task {
            try? await Task.sleep(for: .seconds(replyTimeout))
            if process.isRunning { process.terminate() }
        }
        defer { watchdog.cancel() }

        var shown = ""
        var final: String?
        var failure: String?
        var unparsed = ""   // lines that are not events: usually the tool's own error text
        try await withTaskCancellationHandler {
            for try await line in stdout.fileHandleForReading.bytes.lines {
                switch CLIChatTools.parseLine(tool, line) {
                case .text(let delta):
                    shown += delta
                    let snapshot = shown
                    await MainActor.run { onText(snapshot) }
                case .finished(let text): final = text
                case .failed(let message): failure = message
                case nil: if unparsed.count < maxStderr { unparsed += line + "\n" }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        process.waitUntilExit()

        if let failure { throw failureError(failure) }
        if let final, !final.isEmpty { return final.trimmingCharacters(in: .whitespacesAndNewlines) }
        if !shown.isEmpty { return shown.trimmingCharacters(in: .whitespacesAndNewlines) }
        let errText = String(decoding: stderr.fileHandleForReading.availableData.prefix(maxStderr), as: UTF8.self)
        let text = (errText + unparsed).trimmingCharacters(in: .whitespacesAndNewlines)
        throw failureError(text.isEmpty ? "\(tool.name) gave no answer." : text)
    }

    /// Claude Code reports a missing sign-in as ordinary text; recognise it so the message is useful.
    private static func failureError(_ message: String) -> CLIChatError {
        let lower = message.lowercased()
        if lower.contains("not logged in") || lower.contains("/login") || lower.contains("no authentication information")
            || message.contains("Please set an Auth method") || message.contains("invalid authentication credentials") {
            return .notSignedIn
        }
        return .failed(readable(message))
    }

    /// A tool's error can be a stack trace with warnings around it: keep the first lines that say something.
    private static func readable(_ message: String) -> String {
        let lines = message.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("at ") && !$0.hasPrefix("Skill conflict") && !$0.hasPrefix("[STARTUP]") && !$0.hasPrefix("{") && !$0.hasPrefix("}") }
        let text = lines.prefix(2).joined(separator: " ")
        return text.count > 300 ? String(text.prefix(300)) + "…" : text.isEmpty ? "The tool gave no readable answer." : text
    }

    // MARK: Process

    private static func makeProcess(_ path: String, _ arguments: [String], extraEnvironment: [String: String] = [:]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        // An empty folder: no project instructions or files for the tool to pick up.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("coucou-cli-chat", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        process.currentDirectoryURL = folder
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [URL(fileURLWithPath: path).deletingLastPathComponent().path, "/opt/homebrew/bin",
                       "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
        env.merge(extraEnvironment) { _, new in new }
        process.environment = env
        return process
    }

    /// Runs a short command and returns its output, or nil when it fails to start or times out.
    private static func run(_ path: String, _ arguments: [String], timeout: TimeInterval, mergeStderr: Bool) async -> String? {
        let process = makeProcess(path, arguments)
        let out = Pipe()
        process.standardOutput = out
        process.standardError = mergeStderr ? out : FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(timeout))
            if process.isRunning { process.terminate() }
        }
        defer { watchdog.cancel() }
        var text = ""
        do { for try await line in out.fileHandleForReading.bytes.lines { text += line + "\n" } } catch { return nil }
        process.waitUntilExit()
        return text
    }
}
#endif
