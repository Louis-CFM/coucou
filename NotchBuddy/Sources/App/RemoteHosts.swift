#if !APPSTORE
import AppKit
import Foundation
import SwiftUI

// MARK: - Remote hosts
// Claude Code sessions on other machines, over SSH (the same design as the Linux
// app's windows/src-tauri/src/remote.rs):
//
//   host: claude → nb-hook (nb-hook.py) → ~/.coucou/nb.sock
//                                              │  ssh -R (the user's own ssh, keys and ~/.ssh/config)
//   here: Application Support/NotchBuddy/r/<host>.sock → HookServer, events tagged with the host
//
// SSH is the only authentication: nothing listens on the network. Every script
// sent to a host avoids ', \ and !, so any login shell hands it to `sh -c` unchanged.

enum RemoteSSH {
    struct Failure: Error, Sendable { let message: String }

    /// A destination `ssh` takes as a host and nothing else: never an option.
    static func validHost(_ host: String) -> Bool {
        SSHDestination.valid(host)
    }

    /// The host's socket here.
    static func localSocket(for host: String) -> String {
        HookServer.supportDir.appendingPathComponent("r").appendingPathComponent(SSHDestination.socketName(host)).path
    }

    // Where the relay goes on a host, and the socket it talks to there.
    static let relayDir = ".local/share/coucou/bin"

    /// Makes ~/.coucou private, clears a socket a dead tunnel left there (sshd will
    /// not bind over it) and prints the socket's path.
    static let probe = #"mkdir -p "$HOME/.coucou"; chmod 700 "$HOME/.coucou"; rm -f "$HOME/.coucou/nb.sock"; echo "$HOME/.coucou/nb.sock""#

    /// Prints $HOME, then settings.json; exit 3 when there is none.
    static let readSettings = #"echo "$HOME"; f=$HOME/.claude/settings.json; if [ -e "$f" ]; then cat "$f"; else exit 3; fi"#

    static let checkPython = #"command -v python3 > /dev/null || { echo "python3 is not installed on this host" >&2; exit 1; }; python3 -c "import json, os, socket, sys""#

    /// Takes a file on stdin and puts it in the relay folder, executable.
    static func putRelayFile(_ name: String) -> String {
        #"set -e; d=$HOME/.local/share/coucou/bin; mkdir -p "$d"; t=$d/\#(name).new; cat > "$t"; chmod 755 "$t"; mv -f "$t" "$d/\#(name)""#
    }

    /// Takes the new settings.json on stdin; backs up the old one first (printing
    /// where) and writes through a symlink, keeping the file's mode.
    static func putSettings(stamp: String) -> String {
        #"""
        set -e; f=$HOME/.claude/settings.json; if [ -L "$f" ]; then f=$(readlink -f "$f"); fi; mkdir -p "$(dirname "$f")"
        t=$f.coucou-new; cleanup() { rm -f "$t"; }; trap cleanup EXIT
        if [ -e "$f" ]; then b=$f.bak-\#(stamp); n=0; while [ -e "$b" ]; do n=$((n+1)); b=$f.bak-\#(stamp)-$n; done; cp -p "$f" "$b"; cp -p "$f" "$t"; echo "$b"; else umask 077; fi
        cat > "$t"; mv -f "$t" "$f"
        """#
    }

    /// The relay's wrapper on a host: points nb-hook.py at the tunnel's socket and
    /// always exits 0, so Claude Code is never blocked.
    static let remoteWrapper = """
    #!/bin/sh
    # Coucou hook relay on a remote host: forwards to Coucou on the Mac through its SSH tunnel.
    COUCOU_SOCKET="$HOME/.coucou/nb.sock"; export COUCOU_SOCKET
    out=$(python3 "$(dirname "$0")/nb-hook.py" "$@" 2>/dev/null)
    if [ -n "$out" ]; then echo "$out"; fi
    exit 0

    """

    private final class Drain: @unchecked Sendable { var data = Data() }

    /// Runs `script` on `host` with `input` on its stdin; blocks. Exit 3 is the
    /// script's own "no file"; 255 is ssh failing; anything else non-zero is an error
    /// carrying the last line ssh or the script wrote.
    static func run(_ host: String, _ script: String, input: Data = Data()) -> Result<(stdout: Data, code: Int32), Failure> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "--", host, "sh -c '\(script)'"]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr
        do { try p.run() } catch { return .failure(Failure(message: "ssh: \(error.localizedDescription)")) }
        let err = Drain()
        let errDone = DispatchSemaphore(value: 0)
        let errHandle = stderr.fileHandleForReading
        DispatchQueue.global().async {
            err.data = errHandle.readDataToEndOfFile()
            errDone.signal()
        }
        try? stdin.fileHandleForWriting.write(contentsOf: input)
        try? stdin.fileHandleForWriting.close()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        errDone.wait()
        let code = p.terminationStatus
        if code != 0 && code != 3 {
            return .failure(Failure(message: lastLine(err.data) ?? "ssh exited with \(code)"))
        }
        return .success((out, code))
    }

    static func lastLine(_ data: Data) -> String? {
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }

    // MARK: Installing the hooks on a host

    struct Review: Sendable {
        let host: String
        let install: Bool
        /// settings.json as it will read, shown before anything is written.
        let json: String
        /// The bytes it was computed from (nil: no file); the write is refused if they changed.
        let original: Data?
    }

    /// settings.json on the host, and the relay's path there.
    private static func readRemote(_ host: String) -> Result<(bytes: Data?, relay: String), Failure> {
        switch run(host, readSettings) {
        case .failure(let f): return .failure(f)
        case .success(let (out, code)):
            let split = out.firstIndex(of: UInt8(ascii: "\n")) ?? out.endIndex
            let home = String(decoding: out[out.startIndex..<split], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            guard home.hasPrefix("/") else { return .failure(Failure(message: "\(host): no home directory")) }
            let rest = split < out.endIndex ? Data(out[out.index(after: split)...]) : Data()
            let bytes: Data? = code == 3 ? nil : rest
            return .success((bytes: bytes, relay: "\(home)/\(relayDir)/nb-hook"))
        }
    }

    private static func settingsAfter(_ bytes: Data?, install: Bool, relay: String) throws -> Data {
        let current = try bytes.map { try ClaudeSettingsFile.parse($0, name: "settings.json") } ?? [:]
        let command = "\"\(relay)\""
        let next = try install
            ? HookServer.withClaudeHooks(current, command: command)
            : HookServer.withoutClaudeHooks(current)
        return try JSONSerialization.data(withJSONObject: next, options: [.prettyPrinted, .sortedKeys])
    }

    static func preview(_ host: String, install: Bool) -> Result<Review, Failure> {
        guard validHost(host) else { return .failure(Failure(message: "\(host): not a host name")) }
        switch readRemote(host) {
        case .failure(let f): return .failure(f)
        case .success(let (bytes, relay)):
            do {
                let data = try settingsAfter(bytes, install: install, relay: relay)
                return .success(Review(host: host, install: install, json: String(decoding: data, as: UTF8.self), original: bytes))
            } catch {
                return .failure(Failure(message: error.localizedDescription))
            }
        }
    }

    /// Puts the relay on the host (when installing), then writes what the review
    /// showed, unless settings.json changed since. Returns the backup's path.
    static func apply(_ review: Review) -> Result<String, Failure> {
        let host = review.host
        let current: (bytes: Data?, relay: String)
        switch readRemote(host) {
        case .failure(let f): return .failure(f)
        case .success(let r): current = r
        }
        guard current.bytes == review.original else {
            return .failure(Failure(message: ClaudeSettingsFile.Failure.changed("\(host):~/.claude/settings.json").localizedDescription))
        }
        let data: Data
        do { data = try settingsAfter(current.bytes, install: review.install, relay: current.relay) + Data("\n".utf8) }
        catch { return .failure(Failure(message: error.localizedDescription)) }
        if review.install {
            if case .failure(let f) = run(host, checkPython) { return .failure(f) }
            if case .failure(let f) = run(host, putRelayFile("nb-hook.py"), input: Data(nbHookPythonGitHub.utf8)) { return .failure(f) }
            if case .failure(let f) = run(host, putRelayFile("nb-hook"), input: Data(remoteWrapper.utf8)) { return .failure(f) }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        // ponytail: the file could change between this read and the write (seconds); a remote lock if that ever matters.
        switch run(host, putSettings(stamp: formatter.string(from: Date())), input: data) {
        case .failure(let f): return .failure(f)
        case .success(let (out, _)): return .success(lastLine(out).map { "\(host):\($0)" } ?? "")
        }
    }
}

// MARK: - Tunnel

/// `ssh -R` to one host, kept up with backoff until stopped.
final class RemoteTunnel: @unchecked Sendable {
    let host: String
    private let local: String
    private let lock = NSLock()
    private var stopped = false
    private var process: Process?

    init(host: String, local: String) {
        self.host = host
        self.local = local
    }

    func start() { Thread.detachNewThread { self.loop() } }

    func stop() {
        lock.lock()
        stopped = true
        let p = process
        lock.unlock()
        p?.terminate()
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    private func report(_ state: String, _ error: String = "") {
        let host = self.host
        Task { @MainActor in RemoteHosts.shared.setStatus(host, state: state, error: error) }
    }

    private func loop() {
        var retry: TimeInterval = 2
        while !isStopped {
            report("connecting")
            let started = Date()
            let error: String
            switch RemoteSSH.run(host, RemoteSSH.probe) {
            case .failure(let f):
                error = f.message
            case .success(let (out, _)):
                let remote = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                error = remote.hasPrefix("/") ? forward(remote) : "\(host): no socket path from the host"
            }
            if isStopped { break }
            NSLog("Coucou remote \(host): \(error)")
            report("error", error)
            if Date().timeIntervalSince(started) > 60 { retry = 2 }
            Thread.sleep(forTimeInterval: retry)
            retry = min(retry * 2, 60)
        }
    }

    /// Holds the forward open until ssh ends; returns why it ended.
    private func forward(_ remote: String) -> String {
        // Tied to Coucou: a forward left behind by a killed Coucou would hold the host's socket.
        let (p, _) = TiedProcess.make("/usr/bin/ssh", [
            "-N", "-T",
            "-o", "BatchMode=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2",
            // Its own connection: a shared master would outlive or take down the forward.
            "-o", "ControlPath=none",
            "-R", "\(remote):\(local)",
            "--", host,
        ])
        let stderr = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = stderr
        lock.lock()
        if stopped { lock.unlock(); return "" }
        do { try p.run() } catch { lock.unlock(); return "ssh: \(error.localizedDescription)" }
        process = p
        lock.unlock()
        // Still up after 3 s: the forward was accepted (ExitOnForwardFailure exits sooner).
        for _ in 0..<30 where p.isRunning { Thread.sleep(forTimeInterval: 0.1) }
        if p.isRunning { report("connected") }
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return RemoteSSH.lastLine(err) ?? "ssh exited with \(p.terminationStatus)"
    }
}

// MARK: - State

@MainActor
final class RemoteHosts: ObservableObject {
    static let shared = RemoteHosts()
    private static let key = "remoteHosts"

    struct Status: Equatable {
        var state: String
        var error: String
    }

    @Published private(set) var hosts: [String] = UserDefaults.standard.stringArray(forKey: RemoteHosts.key) ?? []
    @Published private(set) var status: [String: Status] = [:]
    /// The settings.json change on screen, waiting for a click.
    @Published var review: RemoteSSH.Review?
    @Published var message = ""

    private var tunnels: [String: RemoteTunnel] = [:]

    func start() { sync() }

    func add(_ host: String) -> Bool {
        guard let host = SSHDestination.parse(host) else { return false }
        if !hosts.contains(host) { hosts.append(host) }
        save()
        return true
    }

    func remove(_ host: String) {
        hosts.removeAll { $0 == host }
        save()
    }

    func setStatus(_ host: String, state: String, error: String) {
        guard tunnels[host] != nil else { return }
        status[host] = Status(state: state, error: error)
    }

    private func save() {
        UserDefaults.standard.set(hosts, forKey: Self.key)
        sync()
    }

    /// A tunnel and a socket for every host listed, none for any other.
    private func sync() {
        for (host, tunnel) in tunnels where !hosts.contains(host) {
            tunnel.stop()
            HookServer.shared.stopRemote(host: host)
            try? FileManager.default.removeItem(atPath: RemoteSSH.localSocket(for: host))
            tunnels[host] = nil
            status[host] = nil
        }
        let dir = HookServer.supportDir.appendingPathComponent("r")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700 as NSNumber], ofItemAtPath: dir.path)
        for host in hosts where tunnels[host] == nil && RemoteSSH.validHost(host) {
            let local = RemoteSSH.localSocket(for: host)
            HookServer.shared.serveRemote(path: local, host: host)
            let tunnel = RemoteTunnel(host: host, local: local)
            tunnels[host] = tunnel
            status[host] = Status(state: "connecting", error: "")
            tunnel.start()
        }
    }

    func startReview(_ host: String, install: Bool) {
        message = ""
        Task.detached {
            let result = RemoteSSH.preview(host, install: install)
            await MainActor.run {
                switch result {
                case .success(let r): RemoteHosts.shared.review = r
                case .failure(let f): RemoteHosts.shared.message = "❌ \(f.message)"
                }
            }
        }
    }

    func confirmReview() {
        guard let r = review else { return }
        review = nil
        Task.detached {
            let result = RemoteSSH.apply(r)
            await MainActor.run {
                switch result {
                case .success:
                    RemoteHosts.shared.message = r.install
                        ? String(localized: "status.hooks-installed-settings")
                        : String(localized: "status.hooks-removed")
                case .failure(let f): RemoteHosts.shared.message = "❌ \(f.message)"
                }
            }
        }
    }
}

// MARK: - Settings

struct RemoteHostsSection: View {
    @ObservedObject private var remote = RemoteHosts.shared
    @State private var newHost = ""
    @State private var invalid = false

    var body: some View {
        GroupBox(String(localized: "Remote hosts")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "Claude Code sessions on other machines, over SSH with your keys and ~/.ssh/config. Connect to each host once in a terminal first so its host key is known."))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(remote.hosts, id: \.self) { host in
                    hostRow(host)
                }
                HStack(spacing: 10) {
                    TextField(String(localized: "devbox or user@host, as you type it after ssh"), text: $newHost)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                        .onChange(of: newHost) { _, _ in invalid = false }
                    Button(String(localized: "Add"), action: add)
                        .buttonStyle(.borderedProminent)
                }
                if invalid {
                    Text(String(localized: "Not a host name"))
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }
                if let review = remote.review {
                    Text(review.install
                         ? String(localized: "The changes to settings.json on {host}. Coucou also copies its relay to ~/.local/share/coucou/bin there.").replacingOccurrences(of: "{host}", with: review.host)
                         : review.host)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ScrollView {
                        Text(review.json)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                    HStack {
                        Button(String(localized: "hooks.confirm-write")) { remote.confirmReview() }
                            .buttonStyle(.borderedProminent)
                        Button(String(localized: "Cancel")) { remote.review = nil }
                            .buttonStyle(.bordered)
                    }
                }
                if !remote.message.isEmpty {
                    Text(remote.message)
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(6)
        }
    }

    @ViewBuilder private func hostRow(_ host: String) -> some View {
        let status = remote.status[host]
        let state = status?.state ?? "connecting"
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(state == "connected" ? Color.green : (state == "error" ? Color.red : Color.orange))
                    .frame(width: 8, height: 8)
                Text(host)
                    .font(.system(size: 12, design: .monospaced))
                Text(state == "connected" ? String(localized: "Connected")
                     : state == "error" ? String(localized: "Not connected")
                     : String(localized: "chat.connecting"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Button(String(localized: "hooks.install")) { remote.startReview(host, install: true) }
                    .buttonStyle(.borderedProminent)
                Button(String(localized: "hooks.uninstall")) { remote.startReview(host, install: false) }
                    .buttonStyle(.bordered)
                Button(String(localized: "Remove")) { remote.remove(host) }
                    .buttonStyle(.bordered)
            }
            if state == "error", let error = status?.error, !error.isEmpty {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func add() {
        if remote.add(newHost) {
            newHost = ""
        } else {
            invalid = true
        }
    }
}
#endif

/// Open terminal for a remote session: a local terminal running ssh to it.
@MainActor
enum RemoteTerminal {
    struct Place { var host: String; var cwd = ""; var tmux = "" }
    private static var places: [String: Place] = [:]

    static func remember(pillId: String, host: String, payload: [String: Any]) {
        var place = places[pillId] ?? Place(host: host)
        place.host = host
        if let cwd = payload["cwd"] as? String, cwd.hasPrefix("/") { place.cwd = cwd }
        if let tmux = payload["tmux_session"] as? String, isTmuxName(tmux) { place.tmux = tmux }
        places[pillId] = place
    }

    static func forget(pillId: String) { places[pillId] = nil }

    nonisolated static func isTmuxName(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9._-]{1,64}$"#, options: .regularExpression) != nil
    }

    nonisolated static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// ssh into the host: onto its tmux session, else a shell in its folder. nil for a bad host.
    nonisolated static func command(host: String, cwd: String, tmux: String) -> String? {
        guard RemoteSSH.validHost(host) else { return nil }
        let remote = !tmux.isEmpty ? "tmux attach -t \(shQuote(tmux))"
            : !cwd.isEmpty ? "cd \(shQuote(cwd)) && exec \"$SHELL\" -l"
            : "exec \"$SHELL\" -l"
        return "ssh -t -- \(shQuote(host)) \(shQuote(remote))"
    }

    nonisolated static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// False when the pill shows no remote session; iTerm2 when it runs, else Terminal.
    @discardableResult
    static func open(pillId: String) -> Bool {
        guard let place = places[pillId],
              let cmd = command(host: place.host, cwd: place.cwd, tmux: place.tmux) else { return false }
        let iterm = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.googlecode.iterm2").isEmpty
        let script = iterm
            ? """
              tell application id "com.googlecode.iterm2"
                  activate
                  create window with default profile
                  tell current session of current window to write text \(appleScriptString(cmd))
              end tell
              """
            : """
              tell application id "com.apple.Terminal"
                  activate
                  do script \(appleScriptString(cmd))
              end tell
              """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error { appendAppLog("nb.log", "Open terminal (remote): \(error)") }
        return true
    }
}
