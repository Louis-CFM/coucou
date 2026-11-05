import AppKit
import Darwin
import Security

#if !APPSTORE

/// Sends text to a cmux session and starts new chats, through the cmux CLI.
/// The CLI runs only from a bundle that passes the cmux signature check. User text travels as one
/// argv element holding JSON built by JSONSerialization, never through a shell. Tokens and the
/// socket password travel in the child's environment only: never argv, never logged, never on disk.
enum CmuxControl {
    static let passwordKey = "cmux-socket-password"

    enum Failure: Error, Equatable {
        case notRunning, notVerified, noCredential, blockedByDialog, dialogMayBeOpen, notReachableYet, sessionClosed, invalidInput, enterNotSent, busy, promptNotAccepted, launchFilesUnavailable, workspaceNotResolved
        case cli(Int32)

        var message: String {
            switch self {
            case .notRunning:      return String(localized: "cmux is not running.")
            case .notVerified:     return String(localized: "cmux could not be verified.")
            case .noCredential:    return String(localized: "No open cmux session. Add the socket password in Settings, or start one session in cmux.")
            case .blockedByDialog: return String(localized: "Answer the pending request first.")
            case .dialogMayBeOpen: return String(localized: "A request may still be open in cmux. Answer it there first.")
            case .notReachableYet: return String(localized: "This session hasn't reported in to Coucou yet. Send becomes available after its next prompt in cmux.")
            case .sessionClosed:   return String(localized: "That session is no longer open in cmux.")
            case .invalidInput:    return String(localized: "Check the folder / command in Settings.")
            case .promptNotAccepted: return String(localized: "This agent can't take a first prompt that starts with \"-\" or is only a command name. Reword it.")
            case .launchFilesUnavailable: return String(localized: "Coucou couldn't prepare a private folder for this launch. Nothing was started.")
            case .workspaceNotResolved: return String(localized: "The chat opened in cmux, but Coucou could not match it, so your message was not typed. It is back in the field.")
            case .busy:            return String(localized: "Still sending, try again in a moment.")
            case .enterNotSent:    return String(localized: "Text is in the prompt, press Return in cmux.")
            case .cli(let code):   return String(localized: "cmux refused the command (code \(String(code))).")
            }
        }
    }

    /// Serial queue for everything that runs the CLI (one operation at a time).
    private static let queue = DispatchQueue(label: "fr.louisraille.NotchBuddy.cmux-control", qos: .userInitiated)

    // MARK: - socket password (Keychain, loaded once, memory afterwards)

    private final class PasswordCache: @unchecked Sendable {
        private let lock = NSLock()
        private var loaded = false
        private var value: String?
        func get() -> String? {
            lock.lock(); defer { lock.unlock() }
            if !loaded { value = Keychain.load(key: CmuxControl.passwordKey); loaded = true }
            return value
        }
        func set(_ v: String?) {
            lock.lock(); defer { lock.unlock() }
            loaded = true
            value = v
            if let v { Keychain.save(key: CmuxControl.passwordKey, value: v) }
            else { Keychain.delete(key: CmuxControl.passwordKey) }
        }
    }
    private static let passwordCache = PasswordCache()

    static var hasPassword: Bool { !(passwordCache.get() ?? "").isEmpty }

    /// Empty string removes the stored password.
    static func setPassword(_ value: String) {
        passwordCache.set(value.isEmpty ? nil : value)
    }

    // MARK: - CLI

    /// Running cmux bundles first, else the installed one. Called on the main thread.
    @MainActor
    static func candidateBundles() -> (running: Bool, bundles: [URL]) {
        var urls = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == CmuxRouting.bundleId }
            .compactMap { $0.bundleURL }
        let running = !urls.isEmpty
        if let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: CmuxRouting.bundleId),
           !urls.contains(installed) {
            urls.append(installed)
        }
        return (running, urls)
    }

    /// The CLI of the first bundle that passes the signature check. Hashes the bundle: off the main thread.
    nonisolated static func verifiedCLI(bundles: [URL]) -> URL? {
        for bundle in bundles where CmuxJump.bundleIsCmux(bundle) {
            let cli = bundle.appendingPathComponent("Contents/Resources/bin/cmux")
            if FileManager.default.isExecutableFile(atPath: cli.path) { return cli }
        }
        return nil
    }

    /// Environment of the child process, or nil when the credential cannot be used.
    nonisolated static func environment(for credential: CmuxCredential) -> [String: String]? {
        var env: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]
        switch credential {
        case .token(let s):
            guard CmuxRouting.isValidSocketPath(s.socketPath),
                  CmuxRouting.socketFileIsTrusted(path: s.socketPath) else { return nil }
            env["CMUX_SOCKET_PATH"] = s.socketPath
            env["CMUX_SOCKET_CAPABILITY"] = s.capability
            env["CMUX_WORKSPACE_ID"] = s.workspaceId
            env["CMUX_SURFACE_ID"] = s.surfaceId
            return env
        case .password:
            // No socket path here: the CLI resolves its own. A path from a hook payload or from
            // UserDefaults could point the password at a listener the user never chose.
            guard let pw = passwordCache.get(), !pw.isEmpty else { return nil }
            env["CMUX_SOCKET_PASSWORD"] = pw
            return env
        case .none:
            return nil
        }
    }

    /// `environment(for:)` plus, for a token, the check that the listener of the socket is the cmux app:
    /// a token is never handed to a process that is not. Blocks up to a second: off the main thread.
    /// The failure tells the two causes apart: no usable credential, or a peer that is not verified.
    nonisolated static func verifiedEnvironment(for credential: CmuxCredential) -> Result<[String: String], Failure> {
        guard let env = environment(for: credential) else { return .failure(.noCredential) }
        if case .token(let s) = credential {
            guard CmuxRouting.socketPeerIsCmux(path: s.socketPath) else {
                appendAppLog("nb.log", "cmux socket peer not verified")
                return .failure(.notVerified)
            }
        }
        return .success(env)
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        private let limit: Int
        init(limit: Int) { self.limit = limit }
        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            if bytes.count < limit { bytes.append(chunk.prefix(limit - bytes.count)) }
        }
        var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    }

    /// Runs the CLI with a watchdog. status: exit code, -1 could not run, -2 timed out and killed.
    /// stdout is captured (capped at `captureLimit`, 64 KB by default) only when asked; stdin and stderr go to /dev/null.
    nonisolated static func run(cli: URL, args: [String], env: [String: String],
                                timeout: TimeInterval = 2, captureOutput: Bool = false,
                                captureLimit: Int = 65536)
        -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = cli
        p.arguments = args
        p.environment = env
        let pipe = captureOutput ? Pipe() : nil
        p.standardOutput = pipe ?? FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return (-1, "") }
        let box = OutputBox(limit: captureLimit)
        let reader = DispatchGroup()
        if let pipe {
            reader.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let h = pipe.fileHandleForReading
                while true {
                    let chunk = h.availableData
                    if chunk.isEmpty { break }
                    box.append(chunk)
                }
                reader.leave()
            }
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            if done.wait(timeout: .now() + 1) == .timedOut {
                // Ignored SIGTERM: the child holds the token in its environment, do not leave it running.
                kill(p.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 1)
            }
            if captureOutput { _ = reader.wait(timeout: .now() + 1) }
            return (-2, "")
        }
        if captureOutput { _ = reader.wait(timeout: .now() + 1) }
        return (p.terminationStatus, String(data: box.data, encoding: .utf8) ?? "")
    }

    // MARK: - reply

    /// Types `text` into a session and presses Enter. Only ever called from an explicit user action
    /// (Send, Return) or from the single deferred first prompt of a new chat the user started.
    /// The target is `surfaceKey`, else the reply target of the pill (`taskId`).
    /// Typing needs the surface's own token, the one that came with its ids in a hook event of that very
    /// surface: the socket password is never used here, a token of another surface is never lent, and there is
    /// no retry with another credential. A surface known only through discovery or the session file has no
    /// proof that it runs an agent session: until one of its own hook events arrives it is not reachable.
    @MainActor
    static func send(text: String, to taskId: String, surfaceKey: String? = nil,
                     completion: @escaping @MainActor (Failure?) -> Void) {
        let state = AppState.shared
        guard !state.cmuxBusy else { completion(.busy); return }
        guard CmuxRouting.isCmuxTaskId(taskId), let prepared = CmuxRouting.preparePrompt(text) else {
            completion(.invalidInput); return
        }
        let server = HookServer.shared
        // The session closed between the click and now (or never was): not a credential problem.
        guard let key = surfaceKey ?? server.cmuxReplyTarget(for: taskId),
              let target = server.cmuxSurface(key: key), target.taskId == taskId else {
            completion(.sessionClosed); return
        }
        guard server.cmuxCanType(key: key) else { completion(.notReachableYet); return }
        guard server.cmuxCanSend(key: key) else {
            completion(server.cmuxDialogMayBeOpen(key: key) ? .dialogMayBeOpen : .blockedByDialog); return
        }
        guard !target.surfaceId.isEmpty, !target.workspaceId.isEmpty else {
            completion(.notReachableYet); return
        }
        let (running, bundles) = candidateBundles()
        guard running else { completion(.notRunning); return }
        let credential = server.cmuxSendCredential(forKey: key)
        guard credential != CmuxCredential.none else { completion(.notReachableYet); return }
        guard let textParams = CmuxRouting.rpcParams(workspaceId: target.workspaceId, surfaceId: target.surfaceId, text: prepared),
              let keyParams = CmuxRouting.rpcParams(workspaceId: target.workspaceId, surfaceId: target.surfaceId, key: "enter"),
              let textJSON = json(textParams), let keyJSON = json(keyParams) else {
            completion(.invalidInput); return
        }
        state.cmuxBusy = true
        queue.async {
            let result = deliver(key: key, bundles: bundles, credential: credential,
                                 textJSON: textJSON, keyJSON: keyJSON)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    AppState.shared.cmuxBusy = false
                    if let result { appendAppLog("nb.log", "cmux send failed: \(result.message)") }
                    completion(result)
                }
            }
        }
    }

    /// The send gate of one target surface, evaluated on the main thread from the serial queue. Main never
    /// waits on that queue. nil when sending is allowed, else the reason (the same pair `send` reports).
    private nonisolated static func sendGate(_ key: String) -> Failure? {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                let server = HookServer.shared
                if server.cmuxCanSend(key: key) { return nil }
                if !server.cmuxCanType(key: key) { return .notReachableYet }
                return server.cmuxDialogMayBeOpen(key: key) ? .dialogMayBeOpen : .blockedByDialog
            }
        }
    }

    private nonisolated static func deliver(key: String, bundles: [URL], credential: CmuxCredential,
                                            textJSON: String, keyJSON: String) -> Failure? {
        // The signature check (it hashes the bundle, so it is slow) comes first; the gate is evaluated
        // after it and again right before Enter, so a dialog that opens meanwhile is not answered.
        guard let cli = verifiedCLI(bundles: bundles) else { return .notVerified }
        if let blocked = sendGate(key) { return blocked }
        // A token that cannot be shown to be talking to the real cmux never leaves the process.
        let env: [String: String]
        switch verifiedEnvironment(for: credential) {
        case .success(let e): env = e
        case .failure(let f): return f
        }
        let typed = run(cli: cli, args: ["rpc", "surface.send_text", textJSON], env: env, timeout: 3)
        // Any failure ends here, a timeout included: the text may already be typed, never retry.
        if typed.status != 0 { return .cli(typed.status) }
        Thread.sleep(forTimeInterval: 0.15)
        // A residual window of a few milliseconds remains between this check and the key press.
        guard sendGate(key) == nil else { return .enterNotSent }
        let enter = run(cli: cli, args: ["rpc", "surface.send_key", keyJSON], env: env, timeout: 3)
        return enter.status == 0 ? nil : .enterNotSent
    }

    // MARK: - new chat

    /// Creates a workspace in `folder` that runs the launcher's command. Claude: the prompt is not part of
    /// the command, it is kept in memory and typed when the SessionStart of the new surface arrives.
    /// Codex, Grok and Agy never report a start: their prompt is written to a private file that a fixed
    /// wrapper reads (`CmuxLaunchFiles`), the typed line carries no user text, and nothing is awaited or
    /// typed afterwards.
    /// The password is used only here, and only when no session token exists.
    @MainActor
    static func newChat(folder: String, prompt: String, launcher: CmuxLauncher = .claude,
                        completion: @escaping @MainActor (Failure?) -> Void) {
        let state = AppState.shared
        guard !state.cmuxBusy else { completion(.busy); return }
        guard let prepared = CmuxRouting.preparePrompt(prompt),
              CmuxRouting.isExistingFolder(folder),
              CmuxRouting.isValidLaunchCommand(state.cmuxCommand(for: launcher)) else {
            completion(.invalidInput); return
        }
        guard launcher.acceptsPrompt(prepared) else { completion(.promptNotAccepted); return }
        let launcherCommand = state.cmuxCommand(for: launcher)
        let credential = HookServer.shared.cmuxCredential(for: nil, hasPassword: hasPassword)
        guard credential != CmuxCredential.none else { completion(.noCredential); return }
        let (running, bundles) = candidateBundles()
        guard running else { completion(.notRunning); return }
        state.cmuxBusy = true
        queue.async {
            let outcome: Result<Created, Failure> = {
                var command = launcherCommand
                var promptFile: String?
                if !launcher.reportsSessionStart {
                    // The prompt goes in a private file, the typed line holds only paths and the command.
                    guard let files = CmuxLaunchFiles.prepare(prompt: prepared) else { return .failure(.launchFilesUnavailable) }
                    guard let line = launcher.launchLine(command: launcherCommand, wrapperPath: files.wrapperPath,
                                                         promptFile: files.promptFile) else {
                        CmuxLaunchFiles.discard(files.promptFile)
                        return .failure(.launchFilesUnavailable)
                    }
                    command = line
                    promptFile = files.promptFile
                }
                let created = create(bundles: bundles, credential: credential, folder: folder, command: command)
                if case .failure = created, let promptFile { CmuxLaunchFiles.discard(promptFile) }
                return created
            }()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let state = AppState.shared
                    state.cmuxBusy = false
                    switch outcome {
                    case .failure(let f):
                        appendAppLog("nb.log", "cmux new chat failed: \(f.message)")
                        completion(f)
                    case .success(let created):
                        state.cmuxRecentFolders = CmuxRouting.recentFolders(adding: folder, to: state.cmuxRecentFolders)
                        if launcher.reportsSessionStart {
                            let pending = CmuxPendingLaunch(workspaceId: created.workspaceId, socketPath: created.socketPath,
                                                            cwd: folder, prompt: prepared,
                                                            createdAt: Date().timeIntervalSinceReferenceDate)
                            if pending.cannotBeMatched {
                                // Nothing can claim this launch: say so now (the draft goes back) instead of after 90 s.
                                appendAppLog("nb.log", "cmux new chat: workspace not resolved")
                                completion(.workspaceNotResolved)
                                return
                            }
                            HookServer.shared.setCmuxPendingLaunch(pending)
                        } else {
                            state.showCmuxStarted(String(localized: "\(launcher.name) started in cmux. Its session won't appear as a pill here."))
                        }
                        completion(nil)
                    }
                }
            }
        }
    }

    /// `workspaceId` is "" when the UUID could not be resolved; `socketPath` is "" in password mode.
    private struct Created { var workspaceId: String; var socketPath: String }

    private nonisolated static func create(bundles: [URL], credential: CmuxCredential,
                                           folder: String, command: String) -> Result<Created, Failure> {
        guard let cli = verifiedCLI(bundles: bundles) else { return .failure(.notVerified) }
        let env: [String: String]
        switch verifiedEnvironment(for: credential) {
        case .success(let e): env = e
        case .failure(let f): return .failure(f)
        }
        let r = run(cli: cli,
                    args: ["new-workspace", "--cwd", folder, "--command", command, "--focus", "false"],
                    env: env, timeout: 5, captureOutput: true)
        guard r.status == 0 else { return .failure(.cli(r.status)) }
        var socket = ""
        if case .token(let s) = credential { socket = s.socketPath }
        // stdout is `OK workspace:N`, a short ref. Its UUID comes from workspace.list on the same credential.
        var workspaceId = ""
        if let ref = CmuxRouting.workspaceRef(inNewWorkspaceOutput: r.output) {
            // Items need the UUID id and the ref: `--id-format uuids` has no ref since cmux 0.64.25.
            for format in CmuxRouting.workspaceListIdFormats where workspaceId.isEmpty {
                let list = run(cli: cli, args: CmuxRouting.workspaceListArguments(idFormat: format),
                               env: env, timeout: 3, captureOutput: true)
                if list.status == 0 { workspaceId = CmuxRouting.workspaceId(forRef: ref, inListJSON: list.output) ?? "" }
            }
        }
        return .success(Created(workspaceId: workspaceId, socketPath: socket))
    }

    // MARK: - discovery (workspaces, titles, sessions) and branch

    /// Own queue: a slow lookup never delays a send.
    private static let metaQueue = DispatchQueue(label: "fr.louisraille.NotchBuddy.cmux-meta", qos: .utility)

    /// Git branch of `cwd` (read from the HEAD file). nil when it cannot be read. Once per call, no timer.
    @MainActor
    static func fetchBranch(cwd: String, completion: @escaping @MainActor (_ branch: String?) -> Void) {
        metaQueue.async {
            let branch = CmuxRouting.gitBranch(cwd: cwd)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(branch) } }
        }
    }

    /// What the last successful lookup verified: the bundle signature (so the CLI) and the socket peer.
    /// Reused for `verificationReuseInterval` by discovery only; send, new chat and jump never read it.
    private final class ReadVerification: @unchecked Sendable {
        private let lock = NSLock()
        private var cli: URL?
        private var socketPath = ""
        private var at: TimeInterval?
        func reusable(socketPath path: String) -> URL? {
            lock.lock(); defer { lock.unlock() }
            guard let cli, socketPath == path,
                  CmuxRouting.verificationIsFresh(verifiedAt: at, now: ProcessInfo.processInfo.systemUptime),
                  FileManager.default.isExecutableFile(atPath: cli.path) else { return nil }
            return cli
        }
        func store(cli: URL, socketPath path: String) {
            lock.lock(); defer { lock.unlock() }
            self.cli = cli; socketPath = path; at = ProcessInfo.processInfo.systemUptime
        }
    }
    private static let readVerification = ReadVerification()

    /// One discovery: the cmux tree (through the CLI, with `credential`) and the cmux session file.
    /// The tree needs a token (the listener of its socket is verified before the token leaves the process); with
    /// the socket password or without a credential it is nil: the password is never used for a background read.
    /// Both inputs are untrusted and parsed in `CmuxRouting`; nothing read here is ever used as a credential or
    /// as proof that a surface runs an agent. Runs once per call, no timer.
    @MainActor
    static func fetchSnapshot(credential: CmuxCredential, startedAt: TimeInterval,
                              completion: @escaping @MainActor (CmuxSnapshot) -> Void) {
        let (running, candidates) = candidateBundles()
        let bundles = running ? candidates : []
        var socket = ""
        if case .token(let s) = credential { socket = s.socketPath }
        let socketPath = socket
        metaQueue.async {
            let parsed = bundles.isEmpty ? nil : fetchTree(credential: credential, bundles: bundles)
            let sessions = readSessionFile().flatMap { CmuxRouting.parseSessionFile($0, isLive: pidIsLive(pid:start:)) }
            let snapshot = CmuxSnapshot(tree: parsed?.workspaces, sessions: sessions,
                                        socketPath: parsed == nil ? "" : socketPath,
                                        startedAt: startedAt, treeTruncated: parsed?.truncated ?? false)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(snapshot) } }
        }
    }

    private nonisolated static func fetchTree(credential: CmuxCredential, bundles: [URL]) -> CmuxParsedTree? {
        guard case .token(let owner) = credential else { return nil }
        let path = owner.socketPath
        let cli: URL
        let env: [String: String]
        if let cached = readVerification.reusable(socketPath: path),
           let e = environment(for: credential) {
            // Fresh enough: signature and peer were verified for this socket moments ago. The socket file
            // check inside `environment` still runs.
            cli = cached; env = e
        } else {
            guard let verified = verifiedCLI(bundles: bundles),
                  case .success(let e) = verifiedEnvironment(for: credential) else { return nil }
            readVerification.store(cli: verified, socketPath: path)
            cli = verified; env = e
        }
        let r = run(cli: cli, args: ["--id-format", "uuids", "rpc", "system.tree", "{\"all_windows\":true}"],
                    env: env, timeout: 3, captureOutput: true, captureLimit: 1_048_576)
        guard r.status == 0 else { return nil }
        return CmuxRouting.parseTreeChecked(r.output)
    }

    /// `~/.cmuxterm/claude-hook-sessions.json`: a regular file owned by this user, opened without following
    /// a link and without blocking, at most `maxSessionFileBytes`. nil otherwise.
    nonisolated static func readSessionFile(path: String = NSHomeDirectory() + "/.cmuxterm/claude-hook-sessions.json") -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(),
              st.st_size > 0, st.st_size <= off_t(CmuxRouting.maxSessionFileBytes) else { return nil }
        var data = Data(capacity: Int(st.st_size))
        var buffer = [UInt8](repeating: 0, count: 65536)
        while data.count <= CmuxRouting.maxSessionFileBytes {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 { return nil }
            if n == 0 { break }
            data.append(buffer, count: n)
        }
        return data.count <= CmuxRouting.maxSessionFileBytes ? data : nil
    }

    /// True when `pid` is a running process that started at `start` (seconds since the epoch): a recycled
    /// pid has another start time, a zombie is not an agent.
    nonisolated static func pidIsLive(pid: Int32, start: Int) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return Int(info.pbi_start_tvsec) == start && info.pbi_status != UInt32(SZOMB)
    }

    // MARK: - helpers

    private nonisolated static func json(_ params: [String: String]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: params) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

#endif
