import Foundation
import Darwin
import AppKit
import CryptoKit

// MARK: - HookServer
// Listens on a Unix domain socket for events from nb-hook (Claude Code hooks).
// Thread-safe: socket I/O on background threads, state updates dispatched to main queue.

final class HookServer: @unchecked Sendable {
    static let shared = HookServer()

    // Support directory paths
    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchBuddy")
    }
    static var socketPath: String { supportDir.appendingPathComponent("nb.sock").path }
    static var hookScriptPath: String {
        #if APPSTORE
        // Written to ~/.claude/coucou/nb-hook via security-scoped bookmark during hook installation.
        // Real home, not the sandbox container that homeDirectoryForCurrentUser returns here.
        return defaultClaudeDirectory.appendingPathComponent("coucou/nb-hook").path
        #else
        return supportDir.appendingPathComponent("nb-hook").path
        #endif
    }

    // No approval blocking state — notch is notification-only, user answers in VS Code

    private var serverFD: Int32 = -1
    private var pendingApprovalFD: Int32 = -1   // held open while user decides
    private var activeSessionId: String? = nil  // current Claude Code session

    // Socket limits. nb-hook sends one short JSON line and nothing else, so anything
    // bigger, slower or more numerous than this is not a hook and gets dropped.
    private static let maxPayload = 1 << 20          // 1 MiB, same cap as the Windows pipe
    private static let receiveTimeoutSeconds = 5
    private static let maxConcurrentClients = 32
    private let clientsLock = NSLock()
    private var activeClients = 0

    private init() {}

    // MARK: - Start

    func start() {
        #if !APPSTORE
        installHookScript()
        #endif
        Thread.detachNewThread { self.serverThread() }
    }

    // MARK: - Socket server (background thread)

    private func serverThread() {
        let path = Self.socketPath
        // Owner-only folder: other accounts on this Mac must never reach the socket,
        // whatever the umask was when the folder or the socket was created.
        let dir = Self.supportDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(atPath: path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        serverFD = fd

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cpath = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, c) in cpath.enumerated() where i < raw.count { raw[i] = UInt8(bitPattern: c) }
        }

        let bindRC = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bindRC == 0 else { close(fd); return }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 10) == 0 else { close(fd); return }

        while true {
            let clientFD = Darwin.accept(fd, nil, nil)
            guard clientFD >= 0 else { break }
            // Only processes running as this user may talk to us.
            guard Self.peerIsCurrentUser(clientFD), reserveClientSlot() else {
                close(clientFD)
                continue
            }
            Thread.detachNewThread {
                defer { self.releaseClientSlot() }
                self.handleClient(fd: clientFD)
            }
        }
    }

    private static func peerIsCurrentUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    private func reserveClientSlot() -> Bool {
        clientsLock.withLock {
            guard activeClients < Self.maxConcurrentClients else { return false }
            activeClients += 1
            return true
        }
    }

    private func releaseClientSlot() {
        clientsLock.withLock { activeClients -= 1 }
    }

    /// True when the other end of a held connection has gone away (nb-hook killed or timed out).
    private static func peerHasClosed(_ fd: Int32) -> Bool {
        var byte: UInt8 = 0
        let n = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        if n == 0 { return true }                       // orderly shutdown
        if n < 0 { return errno != EAGAIN && errno != EWOULDBLOCK }
        return false
    }

    // MARK: - Client handler (background thread)

    private func handleClient(fd: Int32) {
        // A client that connects and never sends must not hold a thread forever.
        var timeout = timeval(tv_sec: Self.receiveTimeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // Read one newline-delimited JSON line, up to maxPayload bytes.
        var raw = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        outer: while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            for i in 0..<n {
                if buf[i] == UInt8(ascii: "\n") { break outer }
                raw.append(buf[i])
            }
            if raw.count > Self.maxPayload {
                close(fd)
                return
            }
        }

        guard !raw.isEmpty,
              let payload = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            sendLine(fd: fd, text: #"{"ok":true}"#)
            close(fd)
            return
        }

        let eventName = payload["hook_event_name"] as? String ?? ""

        if eventName == "PermissionRequest" {
            // Hold fd open — Claude Code waits for our decision (up to 120s)
            Task { @MainActor in self.processPermissionRequest(fd: fd, payload: payload) }
        } else {
            Task { @MainActor in self.processEvent(name: eventName, payload: payload) }
            sendLine(fd: fd, text: #"{"ok":true}"#)
            close(fd)
        }
    }


    // MARK: - Event → AppState
    // All Claude Code events route to the permanent "integration_claude" task.
    // View switches only happen if VS Code is the currently focused mochi.
    // When not focused: state updates animate the mini bot in the pill; badge shown for alerts.

    @MainActor
    private func processEvent(name: String, payload: [String: Any]) {
        let state = AppState.shared
        let sessionId = payload["session_id"] as? String ?? "unknown"
        let cwd = payload["cwd"] as? String ?? ""
        let rawName = URL(fileURLWithPath: cwd).lastPathComponent
        let projectName = aliasProjectName(rawName.isEmpty ? "Session" : rawName)

        let termProgram = payload["term_program"] as? String ?? ""
        let bundleId    = payload["bundle_id"]    as? String ?? ""
        let isVSCode = termProgram.lowercased().contains("vscode") ||
                       bundleId.lowercased().contains("vscode")
        guard isVSCode else {
            nbLog("Ignored \(name) from \(termProgram.isEmpty ? bundleId : termProgram) (\(projectName))")
            return
        }

        let focused = state.focusId == "integration_claude"

        switch name {

        case "SessionStart":
            activeSessionId = sessionId
            upsertTask(projectName: projectName, cwd: cwd)
            nbLog("SessionStart \(projectName) (\(sessionId.prefix(8)))")
            if state.isPresent { expandIfNeeded(to: .overview) }
            SoundEngine.shared.play("work")

        case "UserPromptSubmit":
            activeSessionId = sessionId
            upsertTask(projectName: projectName, cwd: cwd)
            state.updateTask(id: "integration_claude", state: .thinking)
            if let prompt = payload["prompt"] as? String, !prompt.isEmpty {
                appendStep(id: "integration_claude", step: String(prompt.prefix(60)))
            }
            if state.isPresent { expandIfNeeded(to: .overview) }

        case "PreToolUse":
            activeSessionId = sessionId
            upsertTask(projectName: projectName, cwd: cwd)
            state.updateTask(id: "integration_claude", state: .working)
            let tool = payload["tool_name"] as? String ?? "Tool"
            let input = payload["tool_input"] as? [String: Any] ?? [:]
            let step = frenchStep(tool: tool, input: input)
            appendStep(id: "integration_claude", step: step)
            // Tool name only: commands and paths can carry secrets and must not reach the log.
            nbLog("PreToolUse \(tool)")

        case "PostToolUse":
            state.updateTask(id: "integration_claude", state: .working)

        case "PostToolUseFailure":
            state.updateTask(id: "integration_claude", state: .working)
            appendStep(id: "integration_claude", step: "⚠ failed")

        case "Notification":
            let message = payload["message"] as? String ?? ""
            let lower = message.lowercased()
            if lower.contains("rate limit") || lower.contains("limite d") {
                state.updateTask(id: "integration_claude", state: .ratelimit)
                SoundEngine.shared.play("rate")
            } else if message.hasSuffix("?") {
                state.updateTask(id: "integration_claude", state: .question)
                appendStep(id: "integration_claude", step: message)
            }

        case "Stop":
            state.updateTask(id: "integration_claude", state: .finished)
            if let message = payload["message"] as? String, !message.isEmpty {
                appendStep(id: "integration_claude", step: String(message.prefix(60)))
            }
            SoundEngine.shared.play("finish")
            if focused {
                expandIfNeeded(to: .finished)
            } else {
                setPillBadge(id: "integration_claude", badge: .finished)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) {
                state.updateTask(id: "integration_claude", state: .idle)
                self.clearPillBadge(id: "integration_claude")
            }

        case "StopFailure":
            state.updateTask(id: "integration_claude", state: .error)
            SoundEngine.shared.play("error")
            if focused {
                expandIfNeeded(to: .error)
            } else {
                setPillBadge(id: "integration_claude", badge: .error)
            }

        case "SessionEnd":
            activeSessionId = nil
            state.updateTask(id: "integration_claude", state: .idle)
            clearSession()

        case "SubagentStart":
            appendStep(id: "integration_claude", step: "+ subagent")

        case "SubagentStop":
            appendStep(id: "integration_claude", step: "• subagent done")

        default:
            break
        }
    }

    // MARK: - Helpers

    @MainActor
    private func expandIfNeeded(to view: IslandView) {
        let state = AppState.shared
        let isAlert: Bool
        switch view {
        case .approval, .finished, .error, .confused: isAlert = true
        default: isAlert = false
        }
        if state.mode == .expanded {
            // Only force-switch view for alerts — leave user on their current view otherwise
            if isAlert { state.view = view }
        } else if isAlert {
            // Alerts always force-expand
            NotificationCenter.default.post(name: .hookExpand, object: view)
        } else if state.mode == .hidden {
            // Non-alert work events: reveal compact only, never force-expand
            NotificationCenter.default.post(name: .hookReveal, object: nil)
        }
        // Already compact and non-alert: Mochi state update is enough, no expand
    }

    // MARK: - Permission request (blocking — Claude Code waits for decision)

    @MainActor
    private func processPermissionRequest(fd: Int32, payload: [String: Any]) {
        let state = AppState.shared
        let sessionId = payload["session_id"] as? String ?? "unknown"
        let cwd       = payload["cwd"]        as? String ?? ""
        let rawName   = URL(fileURLWithPath: cwd).lastPathComponent
        let projectName = aliasProjectName(rawName.isEmpty ? "Session" : rawName)

        let termProgram = payload["term_program"] as? String ?? ""
        let bundleId    = payload["bundle_id"]    as? String ?? ""
        let isVSCode = termProgram.lowercased().contains("vscode") ||
                       bundleId.lowercased().contains("vscode")
        guard isVSCode else {
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#)
                close(fd)
            }
            return
        }

        let tool = payload["tool_name"] as? String ?? "Tool"
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        let target = Self.approvalTarget(tool: tool, input: input)
        // Tool name only: the command itself can carry secrets.
        nbLog("PermissionRequest \(tool)")

        // One card, one request. A second request must never quietly replace the first
        // (the user would be deciding on B while A waits); hand it back to the terminal.
        // The exception is a pending request whose nb-hook has already gone away.
        if pendingApprovalFD >= 0 {
            if Self.peerHasClosed(pendingApprovalFD) {
                close(pendingApprovalFD)
                pendingApprovalFD = -1
            } else {
                Task.detached { [weak self] in
                    // "ask" → nb-hook outputs nothing → Claude Code asks in the terminal
                    self?.sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#)
                    close(fd)
                }
                return
            }
        }
        pendingApprovalFD = fd
        activeSessionId = sessionId

        upsertTask(projectName: projectName, cwd: cwd)
        state.updateTask(id: "integration_claude", state: .approval)
        state.pendingApproval = ApprovalInfo(sessionId: sessionId, tool: tool, command: target)
        state.isPinned = true
        SoundEngine.shared.play("approval")

        // Approval always forces the island open — user must be able to respond
        state.focusId = "integration_claude"
        expandIfNeeded(to: .approval)

        let captured = fd
        DispatchQueue.main.asyncAfter(deadline: .now() + 115) { [weak self] in
            guard let self, self.pendingApprovalFD == captured else { return }
            // "ask" → nb-hook outputs nothing → Claude Code re-asks rather than denying
            self.sendApprovalDecision("ask")
        }
    }

    /// Called by ApprovalView buttons. Writes the decision to the waiting nb-hook and cleans up.
    @MainActor
    func sendApprovalDecision(_ decision: String) {
        let fd = pendingApprovalFD
        pendingApprovalFD = -1

        // There is no "always" any more: remembering a rule the user never saw is exactly
        // what the approval card must not do. A stray "always" is a plain allow.
        let json: String
        switch decision {
        case "allow", "always": json = #"{"permissionDecision":"allow"}"#
        case "ask":             json = #"{"permissionDecision":"ask"}"#
        default:                json = #"{"permissionDecision":"deny"}"#
        }

        if fd >= 0 {
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: json)
                close(fd)
            }
        }

        let state = AppState.shared
        state.pendingApproval = nil
        state.isPinned = false
        state.updateTask(id: "integration_claude", state: .working)
        clearPillBadge(id: "integration_claude")
        state.view = state.tasks.isEmpty ? .empty : .overview
    }

    /// Updates integration_claude with the current session project name and cwd.
    @MainActor
    private func upsertTask(projectName: String, cwd: String = "") {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == "integration_claude" }) else { return }
        state.tasks[idx].name = projectName
        if !cwd.isEmpty { state.tasks[idx].sessionCwd = cwd }
    }

    // MARK: - Badge helpers

    @MainActor
    private func setPillBadge(id: String, badge: PillBadge) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[idx].pillBadge = badge
    }

    @MainActor
    private func clearPillBadge(id: String) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[idx].pillBadge = nil
    }

    /// Resets integration_claude to idle, clears steps and project name.
    @MainActor
    private func clearSession() {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == "integration_claude" }) else { return }
        state.tasks[idx].steps = []
        state.tasks[idx].stepIndex = 0
        state.tasks[idx].name = "VS Code"
        state.tasks[idx].pillBadge = nil
    }

    @MainActor
    private func appendStep(id: String, step: String) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[idx].steps.append(step)
        if state.tasks[idx].steps.count > 20 { state.tasks[idx].steps.removeFirst() }
        state.tasks[idx].stepIndex = state.tasks[idx].steps.count - 1
    }

    // MARK: - Project name alias mapping

    private func aliasProjectName(_ name: String) -> String {
        let aliases: [String: String] = [
            "notch-buddy":  "Notch Buddy",
            "notchbuddy":   "Notch Buddy",
            "notch_buddy":  "Notch Buddy",
        ]
        return aliases[name.lowercased()] ?? name
    }

    // MARK: - Approval target

    /// What the approval card shows: the command, file, URL or pattern being authorised,
    /// not just the name of the tool asking. Same field order as the Windows island.
    static func approvalTarget(tool: String, input: [String: Any]) -> String {
        let fields = ["command", "file_path", "notebook_path", "path", "url", "query", "pattern", "prompt"]
        for field in fields {
            if let value = input[field] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return "\(tool) · \(trimmed)" }
            }
        }
        return tool
    }

    // MARK: - French step labels

    private func frenchStep(tool: String, input: [String: Any]) -> String {
        let labels: [String: String] = [
            "Bash":       "Exécute",
            "Read":       "Lit",
            "Write":      "Écrit",
            "Edit":       "Modifie",
            "Glob":       "Cherche",
            "Grep":       "Recherche",
            "WebSearch":  "Recherche web",
            "WebFetch":   "Récupère",
            "TodoWrite":  "Tâches",
            "Task":       "Agent",
            "LS":         "Liste",
            "MultiEdit":  "Modifie",
            "NotebookEdit": "Notebook",
        ]
        let label = labels[tool] ?? tool
        if let cmd = input["command"] as? String {
            let short = String(cmd.prefix(40))
            return "\(label) · \(short)"
        } else if let path = input["path"] as? String {
            return "\(label) · \(URL(fileURLWithPath: path).lastPathComponent)"
        } else if let file = input["file_path"] as? String {
            return "\(label) · \(URL(fileURLWithPath: file).lastPathComponent)"
        } else if let query = input["query"] as? String {
            return "\(label) · \(String(query.prefix(40)))"
        }
        return label
    }

    // MARK: - Logging

    private func nbLog(_ message: String) {
        appendAppLog("nb.log", message)
    }

    private func sendLine(fd: Int32, text: String) {
        let bytes = Array((text + "\n").utf8)
        bytes.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let n = Darwin.send(fd, buffer.baseAddress! + sent, buffer.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    // MARK: - nb-hook script installation

    func installHookScript() {
        #if APPSTORE
        // In App Store mode the script is written during settings hook installation
        // (requires a security-scoped bookmark to ~/.claude chosen by the user)
        #else
        let dir = Self.supportDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let scriptURL = URL(fileURLWithPath: Self.hookScriptPath)
        try? nbHookScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755 as NSNumber],
            ofItemAtPath: scriptURL.path
        )
        #endif
    }

    // MARK: - Outdated hook detection

    /// Returns true if settings.json has a Coucou hook that must be rewritten: a
    /// PermissionRequest timeout under 120 s, or the old App Store command that ran the
    /// Python relay through /bin/sh.
    static func hooksNeedUpdate() -> Bool {
        #if APPSTORE
        guard let claudeURL = resolvedClaudeBookmark() else { return false }
        let accessing = claudeURL.startAccessingSecurityScopedResource()
        defer { if accessing { claudeURL.stopAccessingSecurityScopedResource() } }
        let settingsURL = claudeURL.appendingPathComponent("settings.json")
        #else
        let settingsURL = defaultClaudeDirectory.appendingPathComponent("settings.json")
        #endif
        guard let settings = try? readSettings(at: settingsURL).object,
              let hooks = settings["hooks"] as? [String: Any] else {
            return false
        }
        for (event, value) in hooks {
            for entry in value as? [Any] ?? [] {
                guard let entry = entry as? [String: Any] else { continue }
                for hook in entry["hooks"] as? [[String: Any]] ?? [] {
                    guard let cmd = hook["command"] as? String, isCoucouHookCommand(cmd) else { continue }
                    if cmd.hasPrefix("/bin/sh ") { return true }
                    if event == "PermissionRequest", let timeout = hook["timeout"] as? Int, timeout < 120 {
                        return true
                    }
                }
            }
        }
        return false
    }

    // MARK: - Claude Code settings.json hook installer
    //
    // Rule from CLAUDE.md: read settings.json, take a dated backup, merge without touching
    // anybody else's settings, show the diff, and write only after an explicit click.
    // Same semantics (and failure modes) as windows/src-tauri/src/hooks.rs.

    /// Why an install/uninstall refused to touch settings.json.
    enum HookInstallError: LocalizedError {
        case unreadable(path: String, reason: String)
        case invalidJSON(path: String, reason: String)
        case notAnObject(path: String)
        case changedSincePreview(path: String)
        case backupFailed(reason: String)
        case nothingToWrite

        var errorDescription: String? {
            switch self {
            case .unreadable(let path, let reason):
                return "Can't read \(path): \(reason). Nothing was written."
            case .invalidJSON(let path, let reason):
                return "\(path) isn't valid JSON (\(reason)). Fix or move it, then try again — Coucou won't overwrite it."
            case .notAnObject(let path):
                return "\(path) isn't a JSON object — Coucou won't touch it."
            case .changedSincePreview(let path):
                return "\(path) changed since the preview. Nothing was written — review the new diff."
            case .backupFailed(let reason):
                return "Backup of settings.json failed (\(reason)). Nothing was written."
            case .nothingToWrite:
                return "Nothing to confirm — preview the change again."
            }
        }
    }

    /// Every event the island reacts to, with the timeout written to settings.json.
    /// PermissionRequest waits for a human, so it gets 120 s.
    static let hookEvents: [(String, Int)] = [
        ("SessionStart", 10), ("SessionEnd", 10),
        ("UserPromptSubmit", 10),
        ("PreToolUse", 10), ("PostToolUse", 10), ("PostToolUseFailure", 10),
        ("PermissionRequest", 120),
        ("Notification", 10),
        ("Stop", 10), ("StopFailure", 10),
        ("SubagentStart", 10), ("SubagentStop", 10),
    ]

    /// What the preview showed, and a fingerprint of the exact bytes it was computed from.
    private struct PendingHookWrite {
        let settingsURL: URL
        let data: Data
        let fingerprint: String
    }
    private var pendingHookWrite: PendingHookWrite?

    /// The user's real home folder. In the App Store sandbox homeDirectoryForCurrentUser is
    /// the app container, which is not where Claude Code looks.
    static var realHomeDirectory: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static var defaultClaudeDirectory: URL {
        realHomeDirectory.appendingPathComponent(".claude", isDirectory: true)
    }

    /// Reads settings.json. The only thing that means "start from nothing" is the file not
    /// existing: an unreadable file or JSON we can't parse is an error, because treating it
    /// as empty and writing that back would wipe the user's permissions and other hooks.
    static func readSettings(at url: URL) throws -> (object: [String: Any], raw: Data) {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([:], Data()) }
        let raw: Data
        do {
            raw = try Data(contentsOf: url)
        } catch {
            throw HookInstallError.unreadable(path: url.path, reason: error.localizedDescription)
        }
        // Some editors and PowerShell write a UTF-8 BOM, which JSONSerialization rejects.
        var text = raw
        if text.starts(with: [0xEF, 0xBB, 0xBF]) { text = text.dropFirst(3) }
        if text.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }) {
            return ([:], raw)
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: text)
        } catch {
            throw HookInstallError.invalidJSON(path: url.path, reason: error.localizedDescription)
        }
        guard let object = parsed as? [String: Any] else {
            throw HookInstallError.notAnObject(path: url.path)
        }
        return (object, raw)
    }

    static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A hook command Coucou wrote: the nb-hook relay under NotchBuddy/ or .claude/coucou/.
    /// Another tool whose command merely mentions "coucou" is left alone.
    static func isCoucouHookCommand(_ command: String) -> Bool {
        command.contains("nb-hook") && (command.contains("NotchBuddy") || command.contains("coucou"))
    }

    private static func entryIsOurs(_ entry: Any) -> Bool {
        guard let entry = entry as? [String: Any],
              let hooks = entry["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { ($0["command"] as? String).map(isCoucouHookCommand) ?? false }
    }

    /// Settings with Coucou's hooks added; everything else is left untouched.
    static func merged(_ settings: [String: Any], command: String) -> [String: Any] {
        var root = settings
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, timeout) in hookEvents {
            var list = hooks[event] as? [Any] ?? []
            list.removeAll(where: entryIsOurs)
            list.append(["hooks": [["type": "command", "command": command, "timeout": timeout]]])
            hooks[event] = list
        }
        root["hooks"] = hooks
        return root
    }

    /// Settings with every Coucou entry removed, and nothing else changed.
    static func withoutOurs(_ settings: [String: Any]) -> [String: Any] {
        var root = settings
        guard let hooks = root["hooks"] as? [String: Any] else { return root }
        var out: [String: Any] = [:]
        for (event, value) in hooks {
            if let list = value as? [Any] {
                let kept = list.filter { !entryIsOurs($0) }
                if !kept.isEmpty { out[event] = kept }
            } else {
                out[event] = value
            }
        }
        if out.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = out }
        return root
    }

    static func prettyJSON(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    /// Computes the change and returns the diff the user has to look at before anything
    /// is written. applyPendingHooks() writes exactly this, or nothing.
    private func previewHooks(install: Bool, settingsURL: URL, command: String) throws -> String {
        pendingHookWrite = nil
        let current = try Self.readSettings(at: settingsURL)
        let next = install ? Self.merged(current.object, command: command) : Self.withoutOurs(current.object)
        let before = String(decoding: try Self.prettyJSON(current.object), as: UTF8.self)
        let afterData = try Self.prettyJSON(next)
        pendingHookWrite = PendingHookWrite(settingsURL: settingsURL, data: afterData,
                                            fingerprint: Self.fingerprint(current.raw))
        return Self.unifiedDiff(before, String(decoding: afterData, as: UTF8.self))
    }

    /// Writes what the preview showed, after a dated backup — only if settings.json is still
    /// byte-for-byte the file the preview was computed from. Another tool, the user's editor
    /// or Claude Code itself (a "don't ask again" rule) may have changed it in between.
    @discardableResult
    private func applyPendingHooks() throws -> URL? {
        guard let pending = pendingHookWrite else { throw HookInstallError.nothingToWrite }
        let url = pending.settingsURL
        // Unreadable now → abort before the backup, before anything is touched.
        let current = try Self.readSettings(at: url)
        guard Self.fingerprint(current.raw) == pending.fingerprint else {
            pendingHookWrite = nil
            throw HookInstallError.changedSincePreview(path: url.path)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let backup = try Self.backUp(url)
        try pending.data.write(to: url, options: .atomic)
        pendingHookWrite = nil
        return backup
    }

    /// Removes Coucou's entries (and only those), after a dated backup.
    private func removeHooks(settingsURL: URL) throws {
        let current = try Self.readSettings(at: settingsURL)
        let next = Self.withoutOurs(current.object)
        guard !NSDictionary(dictionary: next).isEqual(to: current.object) else { return }
        let data = try Self.prettyJSON(next)
        // Re-check right before writing so a concurrent edit is never reverted.
        guard Self.fingerprint(try Self.readSettings(at: settingsURL).raw) == Self.fingerprint(current.raw) else {
            throw HookInstallError.changedSincePreview(path: settingsURL.path)
        }
        _ = try Self.backUp(settingsURL)
        try data.write(to: settingsURL, options: .atomic)
    }

    /// Copies settings.json to settings.json.bak-yyyyMMdd-HHmmss (plus a counter if that
    /// name is taken). Returns nil when there is no file yet; throws if the copy fails, so
    /// nothing is ever written without a backup.
    private static func backUp(_ url: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let dir = url.deletingLastPathComponent()
        let base = "\(url.lastPathComponent).bak-\(formatter.string(from: Date()))"
        var backup = dir.appendingPathComponent(base)
        var n = 2
        while FileManager.default.fileExists(atPath: backup.path) {
            backup = dir.appendingPathComponent("\(base)-\(n)")
            n += 1
        }
        do {
            try FileManager.default.copyItem(at: url, to: backup)
        } catch {
            throw HookInstallError.backupFailed(reason: error.localizedDescription)
        }
        return backup
    }

    /// Minimal line diff (LCS) with three lines of context. settings.json is short, so the
    /// plain O(n·m) table is the simplest honest diff. Port of unified_diff in hooks.rs.
    static func unifiedDiff(_ before: String, _ after: String) -> String {
        func lines(_ s: String) -> [String] {
            var l = s.components(separatedBy: "\n")
            if l.last == "" { l.removeLast() }
            return l
        }
        let a = lines(before), b = lines(after)
        let n = a.count, m = b.count
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var out: [String] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                out.append("  " + a[i]); i += 1; j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                out.append("- " + a[i]); i += 1
            } else {
                out.append("+ " + b[j]); j += 1
            }
        }
        while i < n { out.append("- " + a[i]); i += 1 }
        while j < m { out.append("+ " + b[j]); j += 1 }

        let changed = out.indices.filter { out[$0].hasPrefix("+ ") || out[$0].hasPrefix("- ") }
        guard !changed.isEmpty else { return "No change." }
        var keep = Array(repeating: false, count: out.count)
        for idx in changed {
            for k in max(0, idx - 3)..<min(out.count, idx + 4) { keep[k] = true }
        }
        var result = ""
        var gap = false
        for (idx, line) in out.enumerated() {
            if keep[idx] {
                result += line + "\n"
                gap = false
            } else if !gap {
                result += "  …\n"
                gap = true
            }
        }
        return result
    }

    // MARK: - Developer ID build: ~/.claude/settings.json

    /// The command written to settings.json: the relay's quoted path (its shebang runs python3).
    private static var hookCommand: String {
        "\"\(hookScriptPath.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private static var defaultSettingsURL: URL {
        defaultClaudeDirectory.appendingPathComponent("settings.json")
    }

    /// Returns the diff to review — call writeClaudeHooks() to confirm.
    func previewClaudeHooks() throws -> String {
        try previewHooks(install: true, settingsURL: Self.defaultSettingsURL, command: Self.hookCommand)
    }

    /// Writes the previewed change (call after the user confirms the diff).
    func writeClaudeHooks() throws {
        try applyPendingHooks()
    }

    func uninstallClaudeHooks() throws {
        try removeHooks(settingsURL: Self.defaultSettingsURL)
    }

    // MARK: - App Store: hooks via security-scoped bookmark

    #if APPSTORE
    /// The ~/.claude folder the user granted, if the bookmark still resolves.
    static func resolvedClaudeBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: "claudeDirectoryBookmark") else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &isStale),
              !isStale else { return nil }
        return url
    }

    /// The relay lives in the granted folder, so the command is built from that folder's real
    /// path (not the sandbox container), and runs the Python interpreter explicitly: the
    /// sandbox leaves the script quarantined, and /bin/sh would parse the Python as shell and
    /// exit 2 — which Claude Code treats as "block this prompt / tool call".
    static func appStoreHookCommand(claudeURL: URL) -> String {
        let path = claudeURL.appendingPathComponent("coucou/nb-hook").path
        return "/usr/bin/python3 \"\(path.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    func previewClaudeHooksAppStore(claudeURL: URL) throws -> String {
        let accessing = claudeURL.startAccessingSecurityScopedResource()
        defer { if accessing { claudeURL.stopAccessingSecurityScopedResource() } }
        return try previewHooks(install: true,
                                settingsURL: claudeURL.appendingPathComponent("settings.json"),
                                command: Self.appStoreHookCommand(claudeURL: claudeURL))
    }

    func writeClaudeHooksAppStore(claudeURL: URL) throws {
        guard pendingHookWrite != nil else { throw HookInstallError.nothingToWrite }
        let accessing = claudeURL.startAccessingSecurityScopedResource()
        defer { if accessing { claudeURL.stopAccessingSecurityScopedResource() } }

        // Write the nb-hook script into ~/.claude/coucou/nb-hook
        let coucouDir = claudeURL.appendingPathComponent("coucou")
        try FileManager.default.createDirectory(at: coucouDir, withIntermediateDirectories: true)
        let scriptURL = coucouDir.appendingPathComponent("nb-hook")
        try nbHookScriptAppStore.write(to: scriptURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755 as NSNumber], ofItemAtPath: scriptURL.path)

        try applyPendingHooks()
    }

    func uninstallClaudeHooksAppStore(claudeURL: URL) throws {
        let accessing = claudeURL.startAccessingSecurityScopedResource()
        defer { if accessing { claudeURL.stopAccessingSecurityScopedResource() } }
        try removeHooks(settingsURL: claudeURL.appendingPathComponent("settings.json"))
    }
    #endif
}

// MARK: - Local log files

private let appLogMaxBytes: UInt64 = 1_000_000

/// Appends one line to ~/Library/Logs/NotchBuddy/<fileName>. Nothing leaves the machine,
/// but these files end up in bug reports: never pass secrets, commands or response bodies.
/// Control characters are escaped so a logged value can't forge extra lines, and the file
/// starts over past ~1 MB so it can't grow forever (same policy as the Windows log).
func appendAppLog(_ fileName: String, _ message: String, timestampFormat: String = "yyyy-MM-dd HH:mm:ss") {
    let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/NotchBuddy")
    try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    let logFile = logsDir.appendingPathComponent(fileName)

    if let size = (try? FileManager.default.attributesOfItem(atPath: logFile.path))?[.size] as? UInt64,
       size > appLogMaxBytes {
        try? FileManager.default.removeItem(at: logFile)
    }

    let formatter = DateFormatter()
    formatter.dateFormat = timestampFormat
    let line = "\(formatter.string(from: Date())) \(escapedForLog(message))\n"
    guard let data = line.data(using: .utf8) else { return }
    if FileManager.default.fileExists(atPath: logFile.path) {
        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    } else {
        try? data.write(to: logFile)
    }
}

func escapedForLog(_ message: String) -> String {
    var out = String.UnicodeScalarView()
    for scalar in message.unicodeScalars {
        switch scalar {
        case "\n": out.append(contentsOf: "\\n".unicodeScalars)
        case "\r": out.append(contentsOf: "\\r".unicodeScalars)
        case "\t": out.append(" ")
        default:
            if scalar.properties.generalCategory == .control {
                out.append("\u{FFFD}")
            } else {
                out.append(scalar)
            }
        }
    }
    return String(out)
}

// MARK: - Notification names for hook server → controller communication

extension Notification.Name {
    static let hookExpand = Notification.Name("notchBuddy.hookExpand")
}

// MARK: - nb-hook Python script content

private let nbHookScript = """
#!/usr/bin/env python3
# nb-hook — Coucou hook relay for Claude Code
# Reads JSON from stdin, forwards to Coucou via Unix socket, translates response.
import sys, json, os, socket

def main():
    try:
        raw = sys.stdin.buffer.read()
        if not raw:
            return
        payload = json.loads(raw)
    except Exception:
        return

    # Enrich with terminal context
    env = os.environ
    payload.setdefault('term_program', env.get('TERM_PROGRAM', ''))
    payload.setdefault('iterm_session_id', env.get('ITERM_SESSION_ID', ''))
    payload.setdefault('term_session_id', env.get('TERM_SESSION_ID', ''))
    payload.setdefault('bundle_id', env.get('__CFBundleIdentifier', ''))
    if 'cwd' not in payload or not payload['cwd']:
        payload['cwd'] = os.getcwd()

    event = payload.get('hook_event_name', '')
    socket_path = os.path.expanduser(
        '~/Library/Application Support/NotchBuddy/nb.sock'
    )

    if event == 'PermissionRequest':
        # Block and wait for Coucou's decision (Claude Code allows up to 120s)
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(118)
            s.connect(socket_path)
            s.sendall((json.dumps(payload) + '\\n').encode())
            chunks = []
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
                if b'\\n' in chunk:
                    break
            s.close()
            response = b''.join(chunks).decode().strip()
            if response:
                try:
                    resp_obj = json.loads(response)
                    decision = resp_obj.get('permissionDecision', '')
                except Exception:
                    decision = ''
                # A plain allow. Never echo permission_suggestions as updatedPermissions:
                # that would persist rules or mode changes the user never saw.
                if decision in ('allow', 'always'):
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'deny':
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'deny', 'message': 'Denied from Coucou'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                # 'ask' or unknown: fall through → no output → Claude Code re-asks
        except Exception:
            pass
        # App unreachable, timed out, or no explicit decision — print nothing
        # Claude Code will handle the absence of output (re-ask or default behaviour)
        sys.exit(0)

    # All other events: fire-and-forget (0.3s timeout, never blocks)
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.3)
        s.connect(socket_path)
        s.sendall((json.dumps(payload) + '\\n').encode())
        s.close()
    except Exception:
        pass  # Always exit cleanly — never block Claude Code

main()
sys.exit(0)
"""

// MARK: - nb-hook script for App Store (socket in sandboxed container)

private let nbHookScriptAppStore = """
#!/usr/bin/env python3
# nb-hook — Coucou (App Store) hook relay for Claude Code
# Socket lives inside the sandboxed container; script runs outside the sandbox.
import sys, json, os, socket

def main():
    try:
        raw = sys.stdin.buffer.read()
        if not raw:
            return
        payload = json.loads(raw)
    except Exception:
        return

    env = os.environ
    payload.setdefault('term_program', env.get('TERM_PROGRAM', ''))
    payload.setdefault('iterm_session_id', env.get('ITERM_SESSION_ID', ''))
    payload.setdefault('term_session_id', env.get('TERM_SESSION_ID', ''))
    payload.setdefault('bundle_id', env.get('__CFBundleIdentifier', ''))
    if 'cwd' not in payload or not payload['cwd']:
        payload['cwd'] = os.getcwd()

    event = payload.get('hook_event_name', '')
    socket_path = os.path.expanduser(
        '~/Library/Containers/fr.louisraille.Coucou/Data/Library/Application Support/NotchBuddy/nb.sock'
    )

    if event == 'PermissionRequest':
        # Block and wait for Coucou's decision (Claude Code allows up to 120s)
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(118)
            s.connect(socket_path)
            s.sendall((json.dumps(payload) + '\\n').encode())
            chunks = []
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
                if b'\\n' in chunk:
                    break
            s.close()
            response = b''.join(chunks).decode().strip()
            if response:
                try:
                    resp_obj = json.loads(response)
                    decision = resp_obj.get('permissionDecision', '')
                except Exception:
                    decision = ''
                # A plain allow. Never echo permission_suggestions as updatedPermissions:
                # that would persist rules or mode changes the user never saw.
                if decision in ('allow', 'always'):
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'deny':
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'deny', 'message': 'Denied from Coucou'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                # 'ask' or unknown: fall through → no output → Claude Code re-asks
        except Exception:
            pass
        # App unreachable, timed out, or no explicit decision — print nothing
        sys.exit(0)

    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.3)
        s.connect(socket_path)
        s.sendall((json.dumps(payload) + '\\n').encode())
        s.close()
    except Exception:
        pass  # Always exit cleanly — never block Claude Code

main()
sys.exit(0)
"""
