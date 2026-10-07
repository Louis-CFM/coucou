#if !APPSTORE
import Foundation

// MARK: - SessionResumer
//
// Continues a Claude Code conversation in the background:
// `claude -p <text> --resume <session id>`, in the session's own folder.
// Used by the notch's reply panel and by instructions from the iPhone
// (InstructionRunner). The session and folder come from what this Mac saw in
// the hooks. Hooks keep working, so the notch follows the run like any other
// turn and permission requests still need an explicit click.
// The terminal or editor the session was started in doesn't show this turn.
// GitHub build only: the App Store build is sandboxed and can't start `claude`.

@MainActor
final class SessionResumer {
    static let shared = SessionResumer()

    enum Failure: Error, CustomStringConvertible {
        case noSession, folderGone, busy, noClaude, launch(String)
        var description: String {
            switch self {
            case .noSession:  return "No Claude Code session seen yet"
            case .folderGone: return "The session's folder is gone"
            case .busy:       return "Already running a reply for this session"
            case .noClaude:   return "Can't find the claude command"
            case .launch(let message): return "Couldn't start claude: \(message)"
            }
        }
    }

    private var running: [String: Process] = [:]   // by session id

    func isRunning(_ sessionId: String) -> Bool { running[sessionId] != nil }

    /// Starts the run. `onExit` gets the exit status and the end of the output.
    func resume(_ session: ClaudeSessionRef, pillId: String, text: String,
                log: @escaping @MainActor (String) -> Void,
                onExit: (@MainActor (Int32, String) -> Void)? = nil) -> Result<Void, Failure> {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: session.cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(.folderGone)
        }
        guard running[session.sessionId] == nil else { return .failure(.busy) }
        guard let claude = Self.claudeExecutable() else { return .failure(.noClaude) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ["-p", text, "--resume", session.sessionId]
        process.currentDirectoryURL = URL(fileURLWithPath: session.cwd)
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = [URL(fileURLWithPath: claude).deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin",
                       "/usr/bin", "/bin", "/usr/sbin", "/sbin", "\(home)/.local/bin", env["PATH"] ?? ""].joined(separator: ":")
        // The hooks route events by editor or terminal: keep them on the same pill.
        if pillId == "agent_cursor" {
            env["__CFBundleIdentifier"] = "com.todesktop.230313mzl4w4u92"
        } else if let host = session.hostApp {
            env["__CFBundleIdentifier"] = host
            env["TERM_PROGRAM"] = nil
        } else {
            env["TERM_PROGRAM"] = "vscode"
        }
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        // Output goes to a file (a pipe could fill up and stall claude); its
        // end is logged if the run fails.
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/NotchBuddy/instruction-last.log")
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let output = try? FileHandle(forWritingTo: logURL)
        process.standardOutput = output ?? FileHandle.nullDevice
        process.standardError = output ?? FileHandle.nullDevice
        let sessionId = session.sessionId
        process.terminationHandler = { [weak self] finished in
            try? output?.close()
            let data = (try? Data(contentsOf: logURL)) ?? Data()
            let tail = String(decoding: data.suffix(400), as: UTF8.self)
                .replacingOccurrences(of: "\n", with: " ")
            let status = finished.terminationStatus
            Task { @MainActor in
                self?.running[sessionId] = nil
                log(status == 0 ? "finished (\(sessionId.prefix(8)))" : "ended with \(status): \(tail)")
                onExit?(status, tail)
            }
        }
        do {
            try process.run()
            running[sessionId] = process
            log("running in \(URL(fileURLWithPath: session.cwd).lastPathComponent) (\(sessionId.prefix(8))): \(text.count) chars")
            return .success(())
        } catch {
            return .failure(.launch(error.localizedDescription))
        }
    }

    /// Where `claude` usually lives; the app doesn't get the shell's PATH.
    static func claudeExecutable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.claude/local/claude",
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
#endif
