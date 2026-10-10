#if PHONE_LINK && !APPSTORE
import AppKit
import CloudKit

// MARK: - Instructions from the iPhone
//
// The iPhone writes an `Instruction` record (text encrypted) for a session.
// When the user turned it on (Settings → General → iPhone, off by default),
// this Mac checks every 15 s, takes each instruction once (the record is
// deleted on read), and continues that same Claude Code conversation in the
// background: `claude -p <text> --resume <session id>`, in the session's own
// folder. The folder and the session come from what this Mac saw in the
// hooks, never from the iPhone. Hooks keep working, so the notch, the iPhone
// and the permission requests (approved by hand, with Face ID on the phone)
// follow the run like any other turn.
// GitHub build only: the App Store build is sandboxed and can't start `claude`.

@MainActor
final class InstructionRunner {
    static let shared = InstructionRunner()

    nonisolated static let enabledKey = "iPhoneInstructionsEnabled"
    nonisolated static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    private var database: CKDatabase { CKContainer(identifier: CloudProbe.containerID).privateCloudDatabase }
    private var pollTask: Task<Void, Never>?
    private var changeToken: CKServerChangeToken?
    private var running: [String: Process] = [:]   // by session id

    /// Instructions older than this are dropped instead of run.
    private let maxAge: TimeInterval = 10 * 60

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on && CloudProbe.isEnabled { start() } else { stop() }
    }

    func startIfEnabled() {
        if Self.isEnabled { start() }
    }

    func start() {
        guard pollTask == nil else { return }
        log("on: checking for instructions (push, else every 15 s)")
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                // CloudKit pushes reach this Mac (one came in the last half hour): they
                // trigger the check, the poll is only a safety net. Otherwise every 15 s.
                let pushesWork = CloudProbe.shared.lastPushAt.map { Date().timeIntervalSince($0) < 1800 } ?? false
                try? await Task.sleep(for: .seconds(pushesWork ? 90 : 15), tolerance: .seconds(5))
            }
        }
    }

    func stop() {
        guard pollTask != nil else { return }
        pollTask?.cancel()
        pollTask = nil
        log("off")
    }

    /// A CloudKit push arrived: look now instead of at the next poll.
    func checkNow() async {
        guard pollTask != nil else { return }
        await check()
    }

    // MARK: Reading

    /// One check at a time: a push and the poll must never read the same changes twice
    /// (an instruction would run twice).
    private var checking = false
    private var checkAgain = false

    private func check() async {
        guard !checking else { checkAgain = true; return }
        checking = true
        repeat {
            checkAgain = false
            await readAndRun()
        } while checkAgain
        checking = false
    }

    private func readAndRun() async {
        var found: [CKRecord] = []
        do {
            var more = true
            while more {
                let changes = try await database.recordZoneChanges(inZoneWith: SessionSnapshot.zoneID, since: changeToken)
                for (_, result) in changes.modificationResultsByID {
                    if case .success(let mod) = result, mod.record.recordType == "Instruction" { found.append(mod.record) }
                }
                changeToken = changes.changeToken
                more = changes.moreComing
            }
        } catch let error as CKError where error.code == .changeTokenExpired {
            changeToken = nil
            return
        } catch {
            return
        }
        guard !found.isEmpty else { return }
        // Single use: gone from iCloud before anything runs.
        _ = try? await database.modifyRecords(saving: [], deleting: found.map(\.recordID))
        for record in found.sorted(by: { ($0["createdAt"] as? Date ?? .distantPast) < ($1["createdAt"] as? Date ?? .distantPast) }) {
            handle(record)
        }
    }

    private func handle(_ record: CKRecord) {
        let pillId = record["pillId"] as? String ?? ""
        let createdAt = record["createdAt"] as? Date ?? .distantPast
        let text = (record.encryptedValues["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isEnabled else { log("ignored: instructions are off"); return }
        guard Date().timeIntervalSince(createdAt) < maxAge else { log("ignored: older than 10 min"); return }
        guard !text.isEmpty, text.count <= 8000 else { log("ignored: empty or too long"); return }
        guard pillId == "integration_claude" || pillId == "agent_cursor" else { log("ignored: \(pillId) can't take instructions"); return }
        guard let session = TurnRecorder.shared.lastSession(for: pillId) else {
            log("ignored: no Claude Code session seen for \(pillId) yet")
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: session.cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            log("ignored: the session's folder is gone")
            return
        }
        guard running[session.sessionId] == nil else {
            log("ignored: an instruction is already running for this session")
            return
        }
        guard let claude = Self.claudeExecutable() else {
            log("can't find the claude command (looked in ~/.claude/local, Homebrew, /usr/local/bin, ~/.npm-global/bin)")
            return
        }
        run(claude: claude, text: text, sessionId: session.sessionId, cwd: session.cwd, pillId: pillId)
    }

    // MARK: Running

    private func run(claude: String, text: String, sessionId: String, cwd: String, pillId: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ["-p", text, "--resume", sessionId]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = [URL(fileURLWithPath: claude).deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin",
                       "/usr/bin", "/bin", "/usr/sbin", "/sbin", "\(home)/.local/bin", env["PATH"] ?? ""].joined(separator: ":")
        // The hooks route events by editor: keep them on the same pill.
        if pillId == "agent_cursor" {
            env["__CFBundleIdentifier"] = "com.todesktop.230313mzl4w4u92"
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
        process.terminationHandler = { [weak self] finished in
            try? output?.close()
            let data = (try? Data(contentsOf: logURL)) ?? Data()
            let tail = String(decoding: data.suffix(400), as: UTF8.self)
                .replacingOccurrences(of: "\n", with: " ")
            let status = finished.terminationStatus
            Task { @MainActor in
                self?.running[sessionId] = nil
                self?.log(status == 0 ? "finished (\(sessionId.prefix(8)))" : "ended with \(status): \(tail)")
            }
        }
        do {
            try process.run()
            running[sessionId] = process
            log("running in \(URL(fileURLWithPath: cwd).lastPathComponent) (\(sessionId.prefix(8))): \(text.count) chars")
        } catch {
            log("couldn't start claude: \(error.localizedDescription)")
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

    private func log(_ message: String) {
        CloudProbe.shared.log("[instruction] \(message)")
    }
}
#endif
