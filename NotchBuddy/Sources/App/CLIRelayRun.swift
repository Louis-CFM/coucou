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
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let workdir = support.appendingPathComponent("NotchBuddy/relay", isDirectory: true)
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        var request = request
        if cli == .gemini && !request.web {
            let policy = workdir.appendingPathComponent("gemini-no-web.toml")
            try? noWebPolicyTOML.write(to: policy, atomically: true, encoding: .utf8)
            request.noWebPolicy = policy
        }

        let run = Run()
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
        run.process.environment = env
        run.process.standardInput = run.input
        run.process.standardOutput = run.output
        run.process.standardError = run.errors
        let stdin = cli.promptOnStdin ? Data(fullPrompt(cli, request).utf8) : Data()
        let timeout = request.timeout

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { try run.process.run() } catch {
                    continuation.resume(throwing: CLIFailure.failed("Could not start \(cli.displayName): \(error.localizedDescription)"))
                    return
                }
                let timer = DispatchWorkItem { if run.process.isRunning { run.process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                if !stdin.isEmpty { run.input.fileHandleForWriting.write(stdin) }
                try? run.input.fileHandleForWriting.close()
                // Read both pipes to the end before waiting, so a long answer can't fill one and stall.
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { run.stderrData = run.errors.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                let stdoutData = run.output.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                run.process.waitUntilExit()
                timer.cancel()
                if run.process.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: CLIFailure.timedOut(cli.displayName))
                    return
                }
                switch parse(cli, stdout: stdoutData, stderr: run.stderrData, exitCode: run.process.terminationStatus) {
                case .success(let text): continuation.resume(returning: text)
                case .failure(let failure): continuation.resume(throwing: failure)
                }
            }
        }
    }

    /// One run's process and pipes, handed between the queues that drive it.
    private final class Run: @unchecked Sendable {
        let process = Process()
        let input = Pipe(), output = Pipe(), errors = Pipe()
        var stderrData = Data()
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
