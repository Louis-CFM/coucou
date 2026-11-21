import Foundation

#if !APPSTORE
// MARK: - Finding and running the subscription tools (see CLIRelay.swift)

/// Where each tool is installed. The app doesn't get the shell's PATH, so the usual
/// install folders are looked at first (npm, nvm, fnm, Volta, Bun, pnpm, Homebrew, the
/// tools' own installers); for anything else the user's login shell is asked once, in
/// the background, and the views are told when it answers.
final class CLILocator: @unchecked Sendable {
    static let shared = CLILocator()
    static let changed = Notification.Name("notchBuddy.cliLocatorChanged")

    private let lock = NSLock()
    private var found: [SubscriptionCLI: String] = [:]
    private var looked = false
    private var askedShell = false

    /// The tool's executable, or nil when it isn't installed.
    func path(_ cli: SubscriptionCLI) -> String? {
        lock.lock()
        if !looked {
            looked = true
            found = Self.scanFolders()
        }
        let path = found[cli]
        let askShell = path == nil && !askedShell
        if askShell { askedShell = true }
        lock.unlock()
        if askShell { askLoginShell() }
        return path
    }

    func isInstalled(_ cli: SubscriptionCLI) -> Bool { path(cli) != nil }

    /// Looks again (Settings opens, or the user just installed a tool).
    func refresh() {
        lock.lock()
        looked = false
        askedShell = false
        lock.unlock()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    // MARK: Folders

    private static func scanFolders() -> [SubscriptionCLI: String] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var dirs = [
            "\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin",
            "\(home)/.npm-global/bin", "\(home)/.npm/bin", "\(home)/.volta/bin", "\(home)/.bun/bin",
            "\(home)/Library/pnpm", "\(home)/.local/share/pnpm", "\(home)/.yarn/bin",
            "\(home)/.asdf/shims", "\(home)/.local/share/mise/shims", "\(home)/.cursor/bin",
        ]
        // nvm and fnm keep one folder per Node version: newest first.
        dirs += versionDirs("\(home)/.nvm/versions/node") { "\($0)/bin" }
        dirs += versionDirs("\(home)/Library/Application Support/fnm/node-versions") { "\($0)/installation/bin" }
        dirs += versionDirs("\(home)/.local/share/fnm/node-versions") { "\($0)/installation/bin" }
        var out: [SubscriptionCLI: String] = [:]
        for cli in SubscriptionCLI.allCases {
            search: for name in cli.binaries {
                for dir in dirs where fm.isExecutableFile(atPath: "\(dir)/\(name)") {
                    out[cli] = "\(dir)/\(name)"
                    break search
                }
            }
        }
        return out
    }

    private static func versionDirs(_ root: String, _ bin: (String) -> String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return names.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { bin("\(root)/\($0)") }
    }

    // MARK: Login shell

    /// `command -v` for every tool in one interactive login shell (that is where nvm and
    /// friends set PATH up), with no input and a short timeout.
    private func askLoginShell() {
        DispatchQueue.global(qos: .utility).async { [self] in
            let names = SubscriptionCLI.allCases.flatMap(\.binaries)
            let script = names.map { "command -v \($0)" }.joined(separator: "; ")
            let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: shell)
            p.arguments = ["-ilc", script]
            p.standardInput = FileHandle.nullDevice
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return }
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: killer)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            killer.cancel()
            var more: [SubscriptionCLI: String] = [:]
            for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
                let path = line.trimmingCharacters(in: .whitespaces)
                guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { continue }
                let name = (path as NSString).lastPathComponent
                for cli in SubscriptionCLI.allCases where more[cli] == nil && cli.binaries.contains(name) {
                    more[cli] = path
                }
            }
            lock.lock()
            var added = false
            for (cli, path) in more where found[cli] == nil {
                found[cli] = path
                added = true
            }
            lock.unlock()
            if added {
                DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) }
            }
        }
    }
}

extension CLIRelay {

    /// Runs the tool once and returns the text of its answer.
    static func ask(_ cli: SubscriptionCLI, _ request: CLIRequest) async throws -> String {
        guard let exe = CLILocator.shared.path(cli) else { throw CLIFailure.notInstalled(cli.displayName) }
        return try await ask(cli, request, exe: exe, workdir: workdir)
    }

    /// One run of the executable at `exe`, read as `cli`, in `workdir`. Apart from the above so
    /// scripts/test-cli-relay-run.sh can run it on stand-in tools.
    static func ask(_ cli: SubscriptionCLI, _ request: CLIRequest, exe: String, workdir: URL) async throws -> String {
        let run = try launch(cli, request, exe: exe, workdir: workdir)
        return try await run.answer(cli.promptOnStdin ? fullPrompt(cli, request) : "", within: request.timeout)
    }

    /// Starts the tool before its prompt is known (Flow: when the dictation key goes down) and
    /// writes `head`, the prompt's first bytes, at once: Claude Code gives up on a stdin that
    /// stays empty for 3 s. `Pending.finish` writes the rest and waits for the answer. Only for
    /// the tools that read their prompt on stdin; nil for the others or when it can't start.
    static func start(_ cli: SubscriptionCLI, _ request: CLIRequest, head: String) -> Pending? {
        guard cli.promptOnStdin, let exe = CLILocator.shared.path(cli) else { return nil }
        return try? start(cli, request, head: head, exe: exe, workdir: workdir)
    }

    /// `start` with a given executable and folder, for the tests.
    static func start(_ cli: SubscriptionCLI, _ request: CLIRequest, head: String, exe: String, workdir: URL) throws -> Pending {
        let run = try launch(cli, request, exe: exe, workdir: workdir)
        run.write(head)
        return Pending(cli: cli, request: request, run: run)
    }

    /// A run started ahead of its prompt (`start`).
    final class Pending: Sendable {
        let cli: SubscriptionCLI
        /// What it was started with; its prompt is not used.
        let request: CLIRequest
        fileprivate let run: Run

        fileprivate init(cli: SubscriptionCLI, request: CLIRequest, run: Run) {
            self.cli = cli
            self.request = request
            self.run = run
            // One kept but never finished goes away after a while.
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.lifetime) { [weak run] in
                if let run, !run.answering { run.stop() }
            }
        }

        /// One dropped without being finished is stopped, rather than left to read an empty prompt.
        deinit { run.stop() }

        /// How long a run started ahead waits for the rest of its prompt.
        static let lifetime: TimeInterval = 600

        /// Still there, waiting: one that quit before the rest came is no use.
        var isRunning: Bool { run.process.isRunning }

        /// Writes the rest of the prompt; the request's time limit starts now.
        func finish(_ rest: String) async throws -> String {
            try await run.answer(rest, within: request.timeout)
        }

        /// Not needed after all (cancelled, too few words, settings changed): stopped.
        func cancel() { run.stop() }
    }

    private static var workdir: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("NotchBuddy/relay", isDirectory: true)
    }

    /// The process, started, both pipes being read.
    private static func launch(_ cli: SubscriptionCLI, _ request: CLIRequest, exe: String, workdir: URL) throws -> Run {
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        var request = request
        if cli == .gemini && !request.web {
            let policy = workdir.appendingPathComponent("gemini-no-web.toml")
            try? noWebPolicyTOML.write(to: policy, atomically: true, encoding: .utf8)
            request.noWebPolicy = policy
        }

        let run = Run(cli)
        run.process.executableURL = URL(fileURLWithPath: exe)
        run.process.arguments = arguments(cli, request)
        run.process.currentDirectoryURL = workdir
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        // An npm install is a `#!/usr/bin/env node` script: its own folder (nvm keeps Node
        // there) and the usual ones first on PATH so it finds its Node.
        let dir = (exe as NSString).deletingLastPathComponent
        env["PATH"] = ([dir, "/opt/homebrew/bin", "/usr/local/bin"] + [env["PATH"] ?? "/usr/bin:/bin"])
            .joined(separator: ":")
        env["NO_COLOR"] = "1"
        env.merge(environment(cli, request)) { _, added in added }
        run.process.environment = env
        run.process.standardInput = run.input
        run.process.standardOutput = run.output
        run.process.standardError = run.errors
        do { try run.start() } catch {
            throw CLIFailure.failed("Could not start \(cli.displayName): \(error.localizedDescription)")
        }
        return run
    }

    /// One run's process and pipes, handed between the queues that drive it.
    fileprivate final class Run: @unchecked Sendable {
        let cli: SubscriptionCLI
        let process = Process()
        let input = Pipe(), output = Pipe(), errors = Pipe()
        private let reading = DispatchGroup()
        private let lock = NSLock()
        private var stdoutData = Data(), stderrData = Data()
        private var stopped = false
        private var answered = false

        init(_ cli: SubscriptionCLI) { self.cli = cli }

        var timedOut: Bool { lock.withLock { stopped } }
        var answering: Bool { lock.withLock { answered } }

        /// Both pipes are read to the end from the start, so neither can fill up and stall the
        /// tool, however long it waits for its prompt or however long its answer.
        func start() throws {
            try process.run()
            for isOut in [true, false] {
                reading.enter()
                DispatchQueue.global().async { [self] in
                    let data = (isOut ? output : errors).fileHandleForReading.readDataToEndOfFile()
                    lock.withLock { if isOut { stdoutData = data } else { stderrData = data } }
                    reading.leave()
                }
            }
        }

        /// A tool that already quit can't take it: the write fails instead of raising
        /// (SIGPIPE is ignored by the app).
        func write(_ text: String) {
            guard !text.isEmpty else { return }
            try? input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
        }

        /// Writes the rest of the prompt, closes stdin and waits for the answer, `timeout` at most.
        func answer(_ rest: String, within timeout: TimeInterval) async throws -> String {
            lock.withLock { answered = true }
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    let timer = DispatchWorkItem { self.stop() }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                    write(rest)
                    try? input.fileHandleForWriting.close()
                    reading.wait()
                    process.waitUntilExit()
                    timer.cancel()
                    if timedOut || process.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: CLIFailure.timedOut(cli.displayName))
                        return
                    }
                    let (out, err) = lock.withLock { (stdoutData, stderrData) }
                    switch parse(cli, stdout: out, stderr: err, exitCode: process.terminationStatus) {
                    case .success(let text): continuation.resume(returning: text)
                    case .failure(let failure): continuation.resume(throwing: failure)
                    }
                }
            }
        }

        /// Past the time limit, or not needed: asked to stop, then killed a second later if it is
        /// still there (a tool may take its time to quit, or never get the request: a process
        /// started from a dispatch thread can inherit that signal blocked).
        func stop() {
            guard process.isRunning else { return }
            lock.withLock { stopped = true }
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    /// A dropped file copied alone into a fresh folder, so Claude Code can read that file
    /// and nothing else that was ever dropped. Removed by the caller once the run is over.
    static func isolate(_ file: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("coucou-relay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: file, to: dir.appendingPathComponent(file.lastPathComponent))
        return dir
    }

    /// A dropped text file's contents for the tools that can't read files here (up to
    /// 200 KB), or nil for anything else.
    static func inlineText(_ file: URL) -> String? {
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 200_000,
              let data = try? Data(contentsOf: file),
              let text = String(data: data, encoding: .utf8), !text.contains("\u{0}") else { return nil }
        return text
    }
}
#endif
