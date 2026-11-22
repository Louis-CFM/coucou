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
                await self?.publishAgents()
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
        published = nil
        // The iPhone stops offering new tasks.
        let id = CKRecord.ID(recordName: MacAgents.recordName, zoneID: SessionSnapshot.zoneID)
        Task { _ = try? await database.modifyRecords(saving: [], deleting: [id]) }
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
        if record["agent"] is String { handleTask(record); return }
        let pillId = record["pillId"] as? String ?? ""
        let createdAt = record["createdAt"] as? Date ?? .distantPast
        let text = (record.encryptedValues["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isEnabled else { log("ignored: instructions are off"); return }
        guard Date().timeIntervalSince(createdAt) < maxAge else { log("ignored: older than 10 min"); return }
        guard !text.isEmpty, text.count <= 8000 else { log("ignored: empty or too long"); return }
        // A session's own pill ("integration_claude#2") resumes that very session.
        let client = PillCatalog.basePillId(pillId)
        guard client == "integration_claude" || client == "agent_cursor" else { log("ignored: \(pillId) can't take instructions"); return }
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
        if PillCatalog.basePillId(pillId) == "agent_cursor" {
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

    // MARK: New tasks (agent of your choice, in a recent folder)

    /// The agents installed on this Mac and the folders the iPhone may start a task in,
    /// as last published.
    private var published: MacAgents?
    private var tasks: [String: Process] = [:]   // by folder: one task per folder at a time
    private static let projectsKey = "iPhoneRecentProjects"
    private static let resultIdsKey = "iPhoneTaskResultIds"
    private static let maxProjects = 12
    /// A task still running after this is stopped.
    private static let taskTimeout: Duration = .seconds(30 * 60)

    /// The folders agents worked in lately, newest first (kept across launches).
    private func recentProjects() -> [MacAgents.Project] {
        var paths = UserDefaults.standard.stringArray(forKey: Self.projectsKey) ?? []
        for folder in TurnRecorder.shared.folders() where !paths.contains(folder) { paths.insert(folder, at: 0) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        paths = paths.filter { path in
            var isDirectory: ObjCBool = false
            return path != home && path != "/"
                && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        paths = Array(paths.prefix(Self.maxProjects))
        UserDefaults.standard.set(paths, forKey: Self.projectsKey)
        return paths.map { MacAgents.Project(name: URL(fileURLWithPath: $0).lastPathComponent, path: $0) }
    }

    private func moveToFront(_ path: String) {
        var paths = UserDefaults.standard.stringArray(forKey: Self.projectsKey) ?? []
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(Self.maxProjects)), forKey: Self.projectsKey)
    }

    /// Tells the iPhone what it can start here; written only when it changed.
    private func publishAgents() async {
        let now = MacAgents(agents: PhoneAgent.allCases.filter { Self.executable(for: $0) != nil },
                            projects: recentProjects(), updatedAt: Date())
        if let published, published.sameContent(as: now) { return }
        guard let data = try? JSONEncoder().encode(now) else { return }
        let record = CKRecord(recordType: MacAgents.recordType,
                              recordID: CKRecord.ID(recordName: MacAgents.recordName, zoneID: SessionSnapshot.zoneID))
        record.encryptedValues["payload"] = String(decoding: data, as: UTF8.self)
        do {
            _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
            published = now
            log("agents for the iPhone: \(now.agents.map(\.rawValue).joined(separator: ", ")), \(now.projects.count) folders")
        } catch {
            log("couldn't publish the agents: \(error.localizedDescription)")
        }
    }

    /// A new task: the agent and the folder come from the iPhone, but the folder must be one
    /// this Mac published (never any path the iPhone names).
    private func handleTask(_ record: CKRecord) {
        let createdAt = record["createdAt"] as? Date ?? .distantPast
        let taskId = record["taskId"] as? String ?? UUID().uuidString
        let text = (record.encryptedValues["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let path = record.encryptedValues["project"] as? String ?? ""
        guard let agent = PhoneAgent(rawValue: record["agent"] as? String ?? "") else { log("ignored: unknown agent"); return }
        let name = URL(fileURLWithPath: path).lastPathComponent
        func refuse(_ why: String) {
            log("task ignored: \(why)")
            Task { await saveResult(TaskResult(id: taskId, agent: agent, project: name, ok: false, summary: why, endedAt: Date())) }
        }
        guard Self.isEnabled else { log("ignored: instructions are off"); return }
        guard Date().timeIntervalSince(createdAt) < maxAge else { refuse("Sent more than 10 minutes ago."); return }
        guard !text.isEmpty, text.count <= 8000 else { refuse("Empty or too long."); return }
        guard recentProjects().contains(where: { $0.path == path }) else { refuse("That folder isn't in this Mac's recent list."); return }
        guard tasks[path] == nil else { refuse("A task is already running in \(name)."); return }
        guard let executable = Self.executable(for: agent) else { refuse("\(agent.name) isn't installed on this Mac."); return }
        runTask(agent: agent, executable: executable, text: text, path: path, taskId: taskId)
    }

    private func runTask(agent: PhoneAgent, executable: String, text: String, path: String, taskId: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        // No permission flags: each agent follows its own settings, as when it runs without a window
        // (Codex stays read-only unless its config says otherwise; Cursor turns down what needs an OK).
        // Claude Code's requests come to the iPhone through Coucou's hooks, as usual.
        switch agent {
        case .claude: process.arguments = ["-p", text]
        case .codex: process.arguments = ["exec", text]
        case .cursor: process.arguments = ["-p", text, "--output-format", "text"]
        case .antigravity: process.arguments = ["-p", text]
        }
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = [URL(fileURLWithPath: executable).deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin",
                       "/usr/bin", "/bin", "/usr/sbin", "/sbin", "\(home)/.local/bin", env["PATH"] ?? ""].joined(separator: ":")
        switch agent {
        case .claude: env["TERM_PROGRAM"] = "vscode"
        case .cursor: env["__CFBundleIdentifier"] = "com.todesktop.230313mzl4w4u92"
        default: break
        }
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/NotchBuddy/task-\(agent.rawValue)-last.log")
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let output = try? FileHandle(forWritingTo: logURL)
        process.standardOutput = output ?? FileHandle.nullDevice
        process.standardError = output ?? FileHandle.nullDevice
        let name = URL(fileURLWithPath: path).lastPathComponent
        process.terminationHandler = { [weak self] finished in
            try? output?.close()
            let data = (try? Data(contentsOf: logURL)) ?? Data()
            let summary = String(String(decoding: data.suffix(1200), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines).suffix(600))
            let status = finished.terminationStatus
            let result = TaskResult(id: taskId, agent: agent, project: name, ok: status == 0,
                                    summary: summary.isEmpty ? (status == 0 ? "Done." : "Stopped (\(status)).") : summary,
                                    endedAt: Date())
            Task { @MainActor in
                self?.tasks[path] = nil
                self?.log("task \(status == 0 ? "finished" : "ended with \(status)") (\(agent.rawValue) in \(name))")
                await self?.saveResult(result)
            }
        }
        do {
            try process.run()
            tasks[path] = process
            moveToFront(path)
            log("task: \(agent.rawValue) in \(name), \(text.count) chars")
            let pid = process.processIdentifier
            Task { [weak self] in
                try? await Task.sleep(for: Self.taskTimeout)
                guard let self, let running = self.tasks[path], running.processIdentifier == pid, running.isRunning else { return }
                self.log("task stopped after 30 min (\(agent.rawValue) in \(name))")
                running.terminate()
            }
        } catch {
            log("couldn't start \(agent.rawValue): \(error.localizedDescription)")
            Task { await saveResult(TaskResult(id: taskId, agent: agent, project: name, ok: false,
                                               summary: "Couldn't start \(agent.name).", endedAt: Date())) }
        }
    }

    /// The iPhone shows how the task ended. Only the last 10 results are kept.
    private func saveResult(_ result: TaskResult) async {
        guard let data = try? JSONEncoder().encode(result) else { return }
        let record = CKRecord(recordType: TaskResult.recordType,
                              recordID: CKRecord.ID(recordName: "taskresult-\(result.id)", zoneID: SessionSnapshot.zoneID))
        record.encryptedValues["payload"] = String(decoding: data, as: UTF8.self)
        var ids = UserDefaults.standard.stringArray(forKey: Self.resultIdsKey) ?? []
        ids.removeAll { $0 == result.id }
        ids.insert(result.id, at: 0)
        let old = ids.dropFirst(10).map { CKRecord.ID(recordName: "taskresult-\($0)", zoneID: SessionSnapshot.zoneID) }
        UserDefaults.standard.set(Array(ids.prefix(10)), forKey: Self.resultIdsKey)
        _ = try? await database.modifyRecords(saving: [record], deleting: old, savePolicy: .allKeys)
    }

    /// Where each agent's command usually lives; the app doesn't get the shell's PATH.
    static func executable(for agent: PhoneAgent) -> String? {
        switch agent {
        case .claude: return claudeExecutable()
        case .codex: return find(["codex"])
        case .cursor: return find(["cursor-agent"])
        case .antigravity: return find(["agy"])
        }
    }

    private static func find(_ names: [String]) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folders = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin",
                       "\(home)/.bun/bin", "\(home)/.volta/bin", "\(home)/.cargo/bin"]
        for name in names {
            for folder in folders where FileManager.default.isExecutableFile(atPath: "\(folder)/\(name)") {
                return "\(folder)/\(name)"
            }
        }
        return nil
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
