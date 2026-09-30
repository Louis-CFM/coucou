import Foundation
import Darwin
import AppKit

// MARK: - HookServer
// Listens on a Unix domain socket for events from nb-hook (Claude Code and Codex hooks).
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
        // Written to ~/.claude/coucou/nb-hook via security-scoped bookmark during hook installation
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/coucou/nb-hook").path
        #else
        return supportDir.appendingPathComponent("nb-hook").path
        #endif
    }

    // Codex reads hooks from ~/.codex/hooks.json (or inline [hooks] tables in config.toml).
    // Coucou writes hooks.json only — it never touches the user's config.toml.
    static var codexHooksURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/hooks.json")
    }
    static var codexHookScriptPath: String {
        #if APPSTORE
        // Written to ~/.codex/coucou/nb-hook via security-scoped bookmark during hook installation
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/coucou/nb-hook").path
        #else
        return supportDir.appendingPathComponent("nb-hook").path
        #endif
    }

    // No approval blocking state — notch is notification-only, user answers in VS Code

    private var serverFD: Int32 = -1
    private var pendingApprovalFD: Int32 = -1   // held open while user decides
    private var pendingApprovalTaskId: String = "integration_claude"  // pill that owns the pending approval
    private var activeSessionId: String? = nil  // current Claude Code session

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
        guard Darwin.listen(fd, 10) == 0 else { close(fd); return }

        while true {
            let clientFD = Darwin.accept(fd, nil, nil)
            guard clientFD >= 0 else { break }
            Thread.detachNewThread { self.handleClient(fd: clientFD) }
        }
    }

    // MARK: - Client handler (background thread)

    private func handleClient(fd: Int32) {
        // Read newline-delimited JSON
        var raw = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        outer: while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            for i in 0..<n {
                if buf[i] == UInt8(ascii: "\n") { break outer }
                raw.append(buf[i])
            }
        }

        guard !raw.isEmpty,
              let payload = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            sendLine(fd: fd, text: #"{"ok":true}"#)
            close(fd)
            return
        }

        let eventName = payload["hook_event_name"] as? String ?? ""
        // nb-hook tells us which agent it was installed for ("claude" when no argument is passed).
        // Named coucou_agent so it can't collide with Claude's and Codex's own agent_id/agent_type.
        let agent = payload["coucou_agent"] as? String ?? "claude"

        if eventName == "PermissionRequest" {
            // Hold fd open — Claude Code waits for our decision (up to 120s)
            Task { @MainActor in self.processPermissionRequest(fd: fd, payload: payload, agent: agent) }
        } else {
            Task { @MainActor in self.processEvent(name: eventName, payload: payload, agent: agent) }
            sendLine(fd: fd, text: #"{"ok":true}"#)
            close(fd)
        }
    }


    // MARK: - Event → AppState
    // Claude Code events route to "integration_claude", Codex events to "integration_codex".
    // View switches only happen if VS Code is the currently focused mochi.
    // When not focused: state updates animate the mini bot in the pill; badge shown for alerts.

    @MainActor
    private func processEvent(name: String, payload: [String: Any], agent: String) {
        let state = AppState.shared
        let isCodex = agent == "codex"
        let taskId = isCodex ? "integration_codex" : "integration_claude"
        let sessionId = payload["session_id"] as? String ?? "unknown"
        let cwd = payload["cwd"] as? String ?? ""
        let rawName = URL(fileURLWithPath: cwd).lastPathComponent
        let projectName = aliasProjectName(rawName.isEmpty ? "Session" : rawName)

        let termProgram = payload["term_program"] as? String ?? ""
        let bundleId    = payload["bundle_id"]    as? String ?? ""
        let isVSCode = termProgram.lowercased().contains("vscode") ||
                       bundleId.lowercased().contains("vscode")
        // Claude Code sessions are filtered to VS Code; Codex runs anywhere, so every session counts
        guard isCodex || isVSCode else {
            nbLog("Ignored \(name) from \(termProgram.isEmpty ? bundleId : termProgram) (\(projectName))")
            return
        }

        let focused = state.focusId == taskId

        switch name {

        case "SessionStart":
            activeSessionId = sessionId
            upsertTask(id: taskId, projectName: projectName, cwd: cwd)
            nbLog("SessionStart [\(agent)] \(projectName) (\(sessionId.prefix(8)))")
            // A real session start clears a pill left behind by a session that died without Stop.
            // Codex also fires SessionStart mid-turn when it compacts (source = "compact"), and
            // that one must not interrupt a running turn.
            if (payload["source"] as? String) != "compact" {
                state.updateTask(id: taskId, state: .idle)
            }
            if state.isPresent { expandIfNeeded(to: .overview) }
            SoundEngine.shared.play("work")

        case "UserPromptSubmit":
            activeSessionId = sessionId
            upsertTask(id: taskId, projectName: projectName, cwd: cwd)
            state.updateTask(id: taskId, state: .thinking)
            if let prompt = payload["prompt"] as? String, !prompt.isEmpty {
                appendStep(id: taskId, step: oneLine(prompt, limit: 120))
            }
            if state.isPresent { expandIfNeeded(to: .overview) }

        case "PreToolUse":
            activeSessionId = sessionId
            upsertTask(id: taskId, projectName: projectName, cwd: cwd)
            state.updateTask(id: taskId, state: .working)
            let tool = payload["tool_name"] as? String ?? "Tool"
            let input = payload["tool_input"] as? [String: Any] ?? [:]
            let step = frenchStep(tool: tool, input: input)
            appendStep(id: taskId, step: step, note: stepNote(input: input))
            nbLog("PreToolUse [\(agent)] \(step)")

        case "PostToolUse":
            // Codex can deliver a PostToolUse after the turn already ended (a write_stdin poll
            // finishing a long command). A late event must not resurrect a finished session.
            if let current = state.tasks.first(where: { $0.id == taskId })?.state,
               current == .finished || current == .idle {
                nbLog("PostToolUse [\(agent)] ignored (late, state=\(current.rawValue))")
                break
            }
            state.updateTask(id: taskId, state: .working)

        case "PostToolUseFailure":
            if let current = state.tasks.first(where: { $0.id == taskId })?.state,
               current == .finished || current == .idle {
                nbLog("PostToolUseFailure [\(agent)] ignored (late, state=\(current.rawValue))")
                break
            }
            state.updateTask(id: taskId, state: .working)
            appendStep(id: taskId, step: "⚠ failed")

        case "Notification":
            let message = payload["message"] as? String ?? ""
            let lower = message.lowercased()
            if lower.contains("rate limit") || lower.contains("limite d") {
                state.updateTask(id: taskId, state: .ratelimit)
                SoundEngine.shared.play("rate")
            } else if message.hasSuffix("?") {
                state.updateTask(id: taskId, state: .question)
                appendStep(id: taskId, step: oneLine(message))
            }

        case "Stop":
            state.updateTask(id: taskId, state: .finished)
            // Claude Code sends "message"; Codex sends "last_assistant_message"
            let summary = (payload["message"] as? String)
                ?? (payload["last_assistant_message"] as? String) ?? ""
            if !summary.isEmpty {
                appendStep(id: taskId, step: oneLine(summary))
            }
            nbLog("Stop [\(agent)] \(projectName)")
            SoundEngine.shared.play("finish")
            if focused {
                expandIfNeeded(to: .finished)
            } else {
                setPillBadge(id: taskId, badge: .finished)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) {
                state.updateTask(id: taskId, state: .idle)
                self.clearPillBadge(id: taskId)
            }

        case "StopFailure":
            state.updateTask(id: taskId, state: .error)
            SoundEngine.shared.play("error")
            if focused {
                expandIfNeeded(to: .error)
            } else {
                setPillBadge(id: taskId, badge: .error)
            }

        case "Interrupt":
            // Codex only: the user stopped the turn
            activeSessionId = nil
            state.updateTask(id: taskId, state: .idle)
            appendStep(id: taskId, step: "Interrompu")
            nbLog("Interrupt [\(agent)] \(projectName)")

        case "SessionEnd":
            activeSessionId = nil
            state.updateTask(id: taskId, state: .idle)
            clearSession(id: taskId, isCodex: isCodex)
            nbLog("SessionEnd [\(agent)] \(projectName)")

        case "SubagentStart":
            appendStep(id: taskId, step: "+ subagent\(subagentSuffix(payload))")

        case "SubagentStop":
            appendStep(id: taskId, step: "• subagent done\(subagentSuffix(payload))")

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
    private func processPermissionRequest(fd: Int32, payload: [String: Any], agent: String) {
        let state = AppState.shared
        let isCodex = agent == "codex"
        let taskId = isCodex ? "integration_codex" : "integration_claude"
        let sessionId = payload["session_id"] as? String ?? "unknown"
        let cwd       = payload["cwd"]        as? String ?? ""
        let rawName   = URL(fileURLWithPath: cwd).lastPathComponent
        let projectName = aliasProjectName(rawName.isEmpty ? "Session" : rawName)

        let termProgram = payload["term_program"] as? String ?? ""
        let bundleId    = payload["bundle_id"]    as? String ?? ""
        let isVSCode = termProgram.lowercased().contains("vscode") ||
                       bundleId.lowercased().contains("vscode")
        guard isCodex || isVSCode else {
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#)
                close(fd)
            }
            return
        }

        let tool = payload["tool_name"] as? String ?? "Tool"
        var command = tool
        if let input = payload["tool_input"] as? [String: Any] {
            // Codex adds a human-readable approval reason when it has one
            command = input["command"] as? String ?? input["description"] as? String ?? tool
        }
        nbLog("PermissionRequest [\(agent)] \(tool): \(command)")

        if pendingApprovalFD >= 0 {
            let old = pendingApprovalFD
            Task.detached { [weak self] in
                // "ask" → nb-hook outputs nothing → Claude Code re-asks
                self?.sendLine(fd: old, text: #"{"permissionDecision":"ask"}"#)
                close(old)
            }
        }
        pendingApprovalFD = fd
        pendingApprovalTaskId = taskId
        activeSessionId = sessionId

        upsertTask(id: taskId, projectName: projectName, cwd: cwd)
        state.updateTask(id: taskId, state: .approval)
        state.pendingApproval = ApprovalInfo(sessionId: sessionId, tool: tool, command: command)
        state.isPinned = true
        SoundEngine.shared.play("approval")

        // Approval always forces the island open — user must be able to respond
        state.focusId = taskId
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
        let taskId = pendingApprovalTaskId

        let json: String
        switch decision {
        case "allow":  json = #"{"permissionDecision":"allow"}"#
        // Codex fails closed on updatedPermissions, so "always" is sent as a plain allow
        case "always" where taskId == "integration_codex": json = #"{"permissionDecision":"allow"}"#
        case "always": json = #"{"permissionDecision":"always"}"#
        case "ask":    json = #"{"permissionDecision":"ask"}"#
        default:       json = #"{"permissionDecision":"deny"}"#
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
        state.updateTask(id: taskId, state: .working)
        clearPillBadge(id: taskId)
        state.view = state.tasks.isEmpty ? .empty : .overview
    }

    /// Updates an agent pill with the current session project name and cwd.
    @MainActor
    private func upsertTask(id: String = "integration_claude", projectName: String, cwd: String = "") {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
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

    /// Resets an agent pill to idle, clears steps and project name.
    @MainActor
    private func clearSession(id: String, isCodex: Bool) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[idx].steps = []
        state.tasks[idx].stepNotes = []
        state.tasks[idx].stepIndex = 0
        state.tasks[idx].name = isCodex ? "Codex" : "VS Code"
        state.tasks[idx].pillBadge = nil
    }

    @MainActor
    private func appendStep(id: String, step: String, note: String = "") {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[idx].steps.append(step)
        state.tasks[idx].stepNotes.append(note)
        if state.tasks[idx].steps.count > 20 {
            state.tasks[idx].steps.removeFirst()
            state.tasks[idx].stepNotes.removeFirst()
        }
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
            "apply_patch": "Modifie",
            "NotebookEdit": "Notebook",
            // Codex's own local function tools (Claude has Task/TodoWrite for these)
            "update_plan": "Tâches",
            "spawn_agent": "Agent",
        ]
        var label = labels[tool] ?? tool
        // Codex MCP tools arrive as mcp__server__tool — show "server · tool", like Claude's named tools
        if tool.hasPrefix("mcp__") {
            let rest = String(tool.dropFirst(5))
            let parts = rest.components(separatedBy: "__")
            label = parts.count >= 2 ? "\(parts[0]) · \(parts.dropFirst().joined(separator: "__"))" : rest
        }
        // Codex reads, searches and tests through shell commands instead of Claude's Read/Grep tools,
        // so give those the same verbs the ticker already uses for Claude.
        if tool == "Bash", let cmd = input["command"] as? String {
            label = bashVerb(cmd)
        }
        // Codex sends the raw patch for apply_patch — show the first file it touches
        if tool == "apply_patch", let patch = input["command"] as? String {
            for line in patch.split(separator: "\n") {
                for prefix in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where line.hasPrefix(prefix) {
                    let path = String(line.dropFirst(prefix.count))
                    return "\(label) · \(URL(fileURLWithPath: path).lastPathComponent)"
                }
            }
            return label
        }
        if let cmd = input["command"] as? String {
            return "\(label) · \(oneLine(cmd, limit: 120))"
        } else if let path = input["path"] as? String {
            return "\(label) · \(URL(fileURLWithPath: path).lastPathComponent)"
        } else if let file = input["file_path"] as? String {
            return "\(label) · \(URL(fileURLWithPath: file).lastPathComponent)"
        } else if let query = input["query"] as? String {
            return "\(label) · \(oneLine(query, limit: 120))"
        }
        return label
    }

    /// Verb for a shell command: Lit / Cherche / Teste / Exécute.
    private func bashVerb(_ command: String) -> String {
        let first = command.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        switch first {
        case "cat", "bat", "head", "tail", "less", "more", "nl":
            return "Lit"
        case "rg", "grep", "find", "fd", "ls", "tree", "wc":
            return "Cherche"
        default:
            break
        }
        let testRunners = ["unittest", "pytest", "vitest", "jest", "npm test", "npm run test",
                           "cargo test", "go test", "swift test", "make test", "xcodebuild test"]
        if testRunners.contains(where: { command.contains($0) }) { return "Teste" }
        return "Exécute"
    }

    /// Full text behind a step: the whole shell command, or the whole patch for apply_patch.
    private func stepNote(input: [String: Any]) -> String {
        guard let raw = input["command"] as? String else { return "" }
        return String(raw.prefix(1200))
    }

    /// Claude and Codex both report the subagent type — surface it when present.
    private func subagentSuffix(_ payload: [String: Any]) -> String {
        guard let type = payload["agent_type"] as? String, !type.isEmpty else { return "" }
        return " (\(oneLine(type, limit: 20)))"
    }

    // MARK: - Logging

    /// Collapses newlines and tabs so a multi-line command or prompt stays one log line and one ticker row.
    private func oneLine(_ text: String, limit: Int = 60) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }

    private func nbLog(_ message: String) {
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/NotchBuddy")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let logFile = logsDir.appendingPathComponent("nb.log")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(formatter.string(from: Date())) \(oneLine(message, limit: 200))\n"
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
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let scriptURL = URL(fileURLWithPath: Self.hookScriptPath)
        try? nbHookScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755 as NSNumber],
            ofItemAtPath: scriptURL.path
        )
        #endif
    }

    // MARK: - Outdated hook detection

    /// Returns true if settings.json has a Coucou PermissionRequest hook with timeout < 120s.
    static func hooksNeedUpdate() -> Bool {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any],
              let permReqHooks = hooks["PermissionRequest"] as? [[String: Any]] else {
            return false
        }
        for matcher in permReqHooks {
            if let hookList = matcher["hooks"] as? [[String: Any]] {
                for hook in hookList {
                    if let cmd = hook["command"] as? String,
                       (cmd.contains("NotchBuddy") || cmd.contains("coucou")),
                       let timeout = hook["timeout"] as? Int,
                       timeout < 120 {
                        return true
                    }
                }
            }
        }
        return false
    }

    // MARK: - Claude Code settings.json hook installer

    private var _pendingHooksData: Data?

    /// Returns preview JSON without writing — call writeClaudeHooks() to confirm.
    func previewClaudeHooks() throws -> String {
        let data = try buildHooksData()
        _pendingHooksData = data
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Writes the hooks to disk (call after user confirms preview).
    func writeClaudeHooks() throws {
        guard let data = _pendingHooksData else { return }
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        // Backup first
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let stamp = formatter.string(from: Date())
        let backupURL = settingsURL.deletingLastPathComponent()
            .appendingPathComponent("settings.json.bak-\(stamp)")
        try? FileManager.default.copyItem(at: settingsURL, to: backupURL)
        try? FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        try data.write(to: settingsURL, options: .atomic)
        _pendingHooksData = nil
    }

    private func buildHooksData() throws -> Data {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = parsed
        }
        let hookPath = Self.hookScriptPath
        #if APPSTORE
        // Sandboxed apps create quarantined files; /bin/sh bypasses the quarantine flag
        let quotedCmd = "/bin/sh \"\(hookPath.replacingOccurrences(of: "\"", with: "\\\""))\""
        #else
        let quotedCmd = "\"\(hookPath.replacingOccurrences(of: "\"", with: "\\\""))\""
        #endif
        let events: [(String, Int)] = [
            ("SessionStart", 10), ("SessionEnd", 10),
            ("UserPromptSubmit", 10),
            ("PreToolUse", 10), ("PostToolUse", 10), ("PostToolUseFailure", 10),
            ("PermissionRequest", 120),
            ("Notification", 10),
            ("Stop", 10), ("StopFailure", 10),
            ("SubagentStart", 10), ("SubagentStop", 10),
        ]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, timeout) in events {
            var existing = hooks[event] as? [[String: Any]] ?? []
            existing.removeAll { ($0["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String)?.contains("NotchBuddy") == true || ($0["command"] as? String)?.contains("coucou") == true } ?? false }
            existing.append(["hooks": [["type": "command", "command": quotedCmd, "timeout": timeout]]])
            hooks[event] = existing
        }
        settings["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
    }

    func uninstallClaudeHooks() throws {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = settings["hooks"] as? [String: Any] else { return }

        for key in hooks.keys {
            if var matchers = hooks[key] as? [[String: Any]] {
                matchers.removeAll { matcher in
                    (matcher["hooks"] as? [[String: Any]])?.contains {
                        ($0["command"] as? String)?.contains("NotchBuddy") == true ||
                        ($0["command"] as? String)?.contains("coucou") == true
                    } ?? false
                }
                if matchers.isEmpty { hooks.removeValue(forKey: key) }
                else { hooks[key] = matchers }
            }
        }
        settings["hooks"] = hooks
        let newData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try newData.write(to: settingsURL, options: .atomic)
    }

    // MARK: - Codex hooks.json installer
    // Codex discovers hooks in ~/.codex/hooks.json (or inline [hooks] tables in config.toml).
    // Coucou only ever writes hooks.json, merged, after a dated backup — config.toml is left alone.
    // Reminder for the user: Codex asks them to review and trust non-managed hooks with /hooks.

    /// Codex hook events and their timeout (seconds). Codex caps SessionEnd and Interrupt at 3s.
    private static let codexHookEvents: [(String, Int)] = [
        ("SessionStart", 10), ("SessionEnd", 3),
        ("UserPromptSubmit", 10),
        ("PreToolUse", 10), ("PostToolUse", 10),
        ("PermissionRequest", 130),
        ("Stop", 10),
        ("SubagentStart", 10), ("SubagentStop", 10),
        ("Interrupt", 3),
    ]

    /// The command Coucou installs: nb-hook plus the "codex" argument that tags every payload.
    private var codexHookCommand: String {
        "\"\(Self.codexHookScriptPath.replacingOccurrences(of: "\"", with: "\\\""))\" codex"
    }

    /// True when ~/.codex/hooks.json already routes Codex events to Coucou.
    static func codexHooksInstalled() -> Bool {
        guard let data = try? Data(contentsOf: codexHooksURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            (value as? [[String: Any]])?.contains { matcher in
                Self.isCoucouMatcher(matcher)
            } ?? false
        }
    }

    private static func isCoucouMatcher(_ matcher: [String: Any]) -> Bool {
        (matcher["hooks"] as? [[String: Any]])?.contains {
            let cmd = $0["command"] as? String ?? ""
            return cmd.contains("NotchBuddy") || cmd.contains("coucou")
        } ?? false
    }

    private var _pendingCodexHooksData: Data?

    /// Returns the merged hooks.json without writing — call writeCodexHooks() to confirm.
    func previewCodexHooks() throws -> String {
        let data = try buildCodexHooksData(codexDir: Self.codexHooksURL.deletingLastPathComponent())
        _pendingCodexHooksData = data
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Writes hooks.json to disk (call after the user confirms the preview).
    func writeCodexHooks() throws {
        guard let data = _pendingCodexHooksData else { return }
        try writeCodexHooksFile(data: data, codexDir: Self.codexHooksURL.deletingLastPathComponent())
        _pendingCodexHooksData = nil
    }

    func uninstallCodexHooks() throws {
        try removeCoucouHooks(at: Self.codexHooksURL)
    }

    private func writeCodexHooksFile(data: Data, codexDir: URL) throws {
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let hooksURL = codexDir.appendingPathComponent("hooks.json")
        if FileManager.default.fileExists(atPath: hooksURL.path) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmm"
            let backupURL = codexDir.appendingPathComponent("hooks.json.bak-\(formatter.string(from: Date()))")
            try? FileManager.default.copyItem(at: hooksURL, to: backupURL)
        }
        try data.write(to: hooksURL, options: .atomic)
    }

    private func buildCodexHooksData(codexDir: URL) throws -> Data {
        let hooksURL = codexDir.appendingPathComponent("hooks.json")
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: hooksURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, timeout) in Self.codexHookEvents {
            var existing = hooks[event] as? [[String: Any]] ?? []
            existing.removeAll { Self.isCoucouMatcher($0) }
            existing.append(["hooks": [["type": "command", "command": codexHookCommand, "timeout": timeout]]])
            hooks[event] = existing
        }
        root["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    /// Removes only the Coucou matchers from a hooks.json file, leaving other hooks untouched.
    private func removeCoucouHooks(at hooksURL: URL) throws {
        guard let data = try? Data(contentsOf: hooksURL),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = root["hooks"] as? [String: Any] else { return }

        for key in hooks.keys {
            guard var matchers = hooks[key] as? [[String: Any]] else { continue }
            matchers.removeAll { Self.isCoucouMatcher($0) }
            if matchers.isEmpty { hooks.removeValue(forKey: key) }
            else { hooks[key] = matchers }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") }
        else { root["hooks"] = hooks }

        let newData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try newData.write(to: hooksURL, options: .atomic)
    }

    // MARK: - App Store: hooks via security-scoped bookmark

    #if APPSTORE
    /// App Store variant — needs a security-scoped bookmark URL pointing to ~/.claude
    func previewClaudeHooksAppStore(claudeURL: URL) throws -> String {
        let accessing = claudeURL.startAccessingSecurityScopedResource()
        defer { if accessing { claudeURL.stopAccessingSecurityScopedResource() } }
        let data = try buildHooksData(claudeURL: claudeURL)
        _pendingHooksData = data
        return String(data: data, encoding: .utf8) ?? ""
    }

    func writeClaudeHooksAppStore(claudeURL: URL) throws {
        guard let data = _pendingHooksData else { return }
        let accessing = claudeURL.startAccessingSecurityScopedResource()
        defer { if accessing { claudeURL.stopAccessingSecurityScopedResource() } }

        // Write the nb-hook script into ~/.claude/coucou/nb-hook
        let coucouDir = claudeURL.appendingPathComponent("coucou")
        try FileManager.default.createDirectory(at: coucouDir, withIntermediateDirectories: true)
        let scriptURL = coucouDir.appendingPathComponent("nb-hook")
        try nbHookScriptAppStore.write(to: scriptURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755 as NSNumber], ofItemAtPath: scriptURL.path)

        // Write settings.json (with backup)
        let settingsURL = claudeURL.appendingPathComponent("settings.json")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let backupURL = claudeURL.appendingPathComponent("settings.json.bak-\(formatter.string(from: Date()))")
        try? FileManager.default.copyItem(at: settingsURL, to: backupURL)
        try data.write(to: settingsURL, options: .atomic)
        _pendingHooksData = nil
    }

    func uninstallClaudeHooksAppStore(claudeURL: URL) throws {
        let accessing = claudeURL.startAccessingSecurityScopedResource()
        defer { if accessing { claudeURL.stopAccessingSecurityScopedResource() } }
        let settingsURL = claudeURL.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = settings["hooks"] as? [String: Any] else { return }
        for key in hooks.keys {
            if var matchers = hooks[key] as? [[String: Any]] {
                matchers.removeAll { matcher in
                    (matcher["hooks"] as? [[String: Any]])?.contains {
                        ($0["command"] as? String)?.contains("coucou") == true ||
                        ($0["command"] as? String)?.contains("NotchBuddy") == true
                    } ?? false
                }
                if matchers.isEmpty { hooks.removeValue(forKey: key) }
                else { hooks[key] = matchers }
            }
        }
        settings["hooks"] = hooks
        let newData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try newData.write(to: settingsURL, options: .atomic)
    }

    // Codex, App Store variant — same three steps against the user's ~/.codex folder.

    func previewCodexHooksAppStore(codexURL: URL) throws -> String {
        let accessing = codexURL.startAccessingSecurityScopedResource()
        defer { if accessing { codexURL.stopAccessingSecurityScopedResource() } }
        let data = try buildCodexHooksData(codexDir: codexURL)
        _pendingCodexHooksData = data
        return String(data: data, encoding: .utf8) ?? ""
    }

    func writeCodexHooksAppStore(codexURL: URL) throws {
        guard let data = _pendingCodexHooksData else { return }
        let accessing = codexURL.startAccessingSecurityScopedResource()
        defer { if accessing { codexURL.stopAccessingSecurityScopedResource() } }

        // Write the nb-hook script into ~/.codex/coucou/nb-hook
        let coucouDir = codexURL.appendingPathComponent("coucou")
        try FileManager.default.createDirectory(at: coucouDir, withIntermediateDirectories: true)
        let scriptURL = coucouDir.appendingPathComponent("nb-hook")
        try nbHookScriptAppStore.write(to: scriptURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755 as NSNumber], ofItemAtPath: scriptURL.path)

        try writeCodexHooksFile(data: data, codexDir: codexURL)
        _pendingCodexHooksData = nil
    }

    func uninstallCodexHooksAppStore(codexURL: URL) throws {
        let accessing = codexURL.startAccessingSecurityScopedResource()
        defer { if accessing { codexURL.stopAccessingSecurityScopedResource() } }
        try removeCoucouHooks(at: codexURL.appendingPathComponent("hooks.json"))
    }

    private func buildHooksData(claudeURL: URL) throws -> Data {
        let settingsURL = claudeURL.appendingPathComponent("settings.json")
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = parsed
        }
        let hookPath = Self.hookScriptPath
        let quotedCmd = "/bin/sh \"\(hookPath.replacingOccurrences(of: "\"", with: "\\\""))\""
        let events: [(String, Int)] = [
            ("SessionStart", 10), ("SessionEnd", 10),
            ("UserPromptSubmit", 10),
            ("PreToolUse", 10), ("PostToolUse", 10), ("PostToolUseFailure", 10),
            ("PermissionRequest", 120),
            ("Notification", 10),
            ("Stop", 10), ("StopFailure", 10),
            ("SubagentStart", 10), ("SubagentStop", 10),
        ]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, timeout) in events {
            var existing = hooks[event] as? [[String: Any]] ?? []
            existing.removeAll { ($0["hooks"] as? [[String: Any]])?.contains {
                ($0["command"] as? String)?.contains("coucou") == true ||
                ($0["command"] as? String)?.contains("NotchBuddy") == true
            } ?? false }
            existing.append(["hooks": [["type": "command", "command": quotedCmd, "timeout": timeout]]])
            hooks[event] = existing
        }
        settings["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
    }
    #endif
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
    # 'claude' or 'codex'. Accepts '--agent codex' and the positional form the hook command uses.
    args = sys.argv[1:]
    if len(args) >= 2 and args[0] == '--agent':
        agent = args[1]
    else:
        agent = args[0] if args else 'claude'
    payload.setdefault('coucou_agent', agent)
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
                if decision == 'allow':
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'always' and agent != 'codex':
                    # Let Claude Code persist the rule via updatedPermissions
                    suggestions = payload.get('permission_suggestions', [])
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow', 'updatedPermissions': suggestions}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'always':
                    # Codex fails closed on updatedPermissions — answer a plain allow instead
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
    # 'claude' or 'codex'. Accepts '--agent codex' and the positional form the hook command uses.
    args = sys.argv[1:]
    if len(args) >= 2 and args[0] == '--agent':
        agent = args[1]
    else:
        agent = args[0] if args else 'claude'
    payload.setdefault('coucou_agent', agent)
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
                if decision == 'allow':
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'always' and agent != 'codex':
                    # Let Claude Code persist the rule via updatedPermissions
                    suggestions = payload.get('permission_suggestions', [])
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow', 'updatedPermissions': suggestions}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'always':
                    # Codex fails closed on updatedPermissions — answer a plain allow instead
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
