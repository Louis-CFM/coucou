import Foundation
import Darwin
import AppKit
import SwiftUI
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
    static var socketPath: String {
        #if APPSTORE
        // Container home root keeps path ≤ 103 bytes (sun_path limit on macOS is 104 incl. NUL)
        // /Users/louis/Library/Containers/fr.louisraille.Coucou/Data/nb.sock = 66 bytes ✓
        return NSHomeDirectory() + "/nb.sock"
        #else
        return supportDir.appendingPathComponent("nb.sock").path
        #endif
    }
    // hookScriptPath is only used by the non-App Store build.
    // App Store build derives the command from the panel-selected claudeURL in buildHooksData(claudeURL:).
    static var hookScriptPath: String { supportDir.appendingPathComponent("nb-hook").path }

    // No approval blocking state — notch is notification-only, user answers in VS Code

    private static let maxPayload = 1_048_576          // 1 MB — reject oversized messages
    private static let receiveTimeoutSeconds: Int = 5   // SO_RCVTIMEO on client sockets
    private static let maxConnections = 32              // concurrent connection ceiling

    private var serverFD: Int32 = -1
    private let connectionLock = NSLock()
    private var connectionCount = 0
    private var pendingApprovalFD: Int32 = -1         // held open while user decides
    private var approvalFDSource: (any DispatchSourceRead)? = nil  // monitors pendingApprovalFD
    private var pendingQuestionFD: Int32 = -1         // held open while user answers AskUserQuestion
    private var questionFDSource: (any DispatchSourceRead)? = nil  // monitors pendingQuestionFD

    /// True when a real nb-hook connection is holding the approval fd open.
    @MainActor var hasRealPendingApproval: Bool { pendingApprovalFD >= 0 }
    /// True when a real nb-hook connection is holding the question fd open.
    @MainActor var hasRealPendingQuestion: Bool { pendingQuestionFD >= 0 }
    private var questionPillId: String = ""           // pill that owns the pending question
    private var questionSessionId: String = ""        // sessionId for the pending question (recap tracking)
    private var focusBeforeQuestion: String? = nil    // saved focus to restore after question
    private var activeSessionId: String? = nil        // current Claude Code session
    private var focusBeforeApproval: String? = nil    // saved focus to restore after approval

    private init() {}

    // MARK: - Approval fd helpers

    @MainActor
    private func cancelApprovalFDSource() {
        approvalFDSource?.cancel()
        approvalFDSource = nil
    }

    /// Cancels the approval fd source (which closes the fd via its cancel handler), shows a
    /// 3-second note, clears approval state, then collapses the island.
    @MainActor
    private func dismissApprovalCard(note: String) {
        // cancelApprovalFDSource() triggers the cancel handler which closes the fd.
        // Never close the fd here directly — Apple requires it to happen in the cancel handler.
        cancelApprovalFDSource()
        pendingApprovalFD = -1
        let state = AppState.shared
        let pillId = state.pendingApproval?.pillId ?? "integration_claude"
        state.pendingApproval = nil
        state.isPinned = false
        state.updateTask(id: pillId, state: .working)
        clearPillBadge(id: pillId)
        // Restore focus to the pill that was focused before the approval card appeared.
        if let prev = focusBeforeApproval {
            focusBeforeApproval = nil
            if state.focusId == pillId, state.tasks.contains(where: { $0.id == prev }) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.focusId = prev }
            }
        }
        state.noteMessage = note
        state.view = .note
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            NotificationCenter.default.post(name: .islandCollapse, object: nil)
        }
    }

    // MARK: - Question fd helpers

    @MainActor
    private func cancelQuestionFDSource() {
        questionFDSource?.cancel()
        questionFDSource = nil
    }

    @MainActor
    private func dismissQuestionCard(note: String) {
        cancelQuestionFDSource()
        pendingQuestionFD = -1
        let state = AppState.shared
        let pillId = questionPillId
        state.pendingQuestion = nil
        state.isPinned = false
        state.updateTask(id: pillId, state: .working)
        clearPillBadge(id: pillId)
        if let prev = focusBeforeQuestion {
            focusBeforeQuestion = nil
            if state.focusId == pillId, state.tasks.contains(where: { $0.id == prev }) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.focusId = prev }
            }
        }
        if !note.isEmpty {
            state.noteMessage = note
            state.view = .note
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                NotificationCenter.default.post(name: .islandCollapse, object: nil)
            }
        } else {
            state.view = state.tasks.isEmpty ? .empty : .overview
        }
    }

    /// Called by QuestionView. Sends answers JSON and cleans up.
    @MainActor
    func sendQuestionAnswers(_ answers: [String: Any]) {
        // Only intercept a demo question — real questions always have a live fd.
        if DemoEngine.shared.isActive, pendingQuestionFD < 0 {
            AppState.shared.pendingQuestion = nil
            AppState.shared.isPinned = false
            AppState.shared.view = AppState.shared.tasks.isEmpty ? .empty : .overview
            DemoEngine.shared.handleQuestionAnswered(answers: answers)
            return
        }
        let fd = pendingQuestionFD
        pendingQuestionFD = -1
        let source = questionFDSource
        questionFDSource = nil
        let sid = questionSessionId
        questionSessionId = ""
        if fd >= 0, let data = try? JSONSerialization.data(withJSONObject: ["permissionDecision": "answer", "answers": answers], options: .withoutEscapingSlashes),
           let json = String(data: data, encoding: .utf8) {
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: json)
                DispatchQueue.main.async { source?.cancel() }
            }
        } else {
            source?.cancel()
        }
        if !sid.isEmpty { RecapStore.shared.recordQuestionAnswered(sessionId: sid) }
        dismissQuestionCard(note: "")
    }

    /// Called by QuestionView.onDisappear — card left screen without an explicit answer.
    /// Sends "ask" immediately to unblock nb-hook; does NOT navigate (view already changed).
    @MainActor
    func releaseQuestionFD() {
        guard pendingQuestionFD >= 0 else { return }
        let fd = pendingQuestionFD
        pendingQuestionFD = -1
        let source = questionFDSource
        questionFDSource = nil
        AppState.shared.pendingQuestion = nil
        Task.detached { [weak self] in
            self?.sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#)
            DispatchQueue.main.async { source?.cancel() }
        }
    }

    /// Called by QuestionView "Reply in terminal" button.
    @MainActor
    func sendQuestionAsk() {
        let fd = pendingQuestionFD
        pendingQuestionFD = -1
        let source = questionFDSource
        questionFDSource = nil
        if fd >= 0 {
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#)
                DispatchQueue.main.async { source?.cancel() }
            }
        } else {
            source?.cancel()
        }
        dismissQuestionCard(note: "")
    }

    /// Returns the tool_input serialized as sorted-keys JSON, "" if absent or empty.
    /// Same computation used in processPermissionRequest and processEvent to match PostToolUse.
    private static func approvalInputKey(_ input: [String: Any]) -> String {
        guard !input.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: input, options: .sortedKeys),
              let str = String(data: data, encoding: .utf8) else { return "" }
        return str
    }

    // MARK: - Start

    func start() {
        // Ensure support directory exists (mode 0700 — not world-readable)
        let dir = Self.supportDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700 as NSNumber], ofItemAtPath: dir.path)
        #if !APPSTORE
        installHookScript()
        #endif
        Thread.detachNewThread { self.serverThread() }
    }

    // MARK: - Socket server (background thread)

    private func serverThread() {
        let path = Self.socketPath
        // sun_path on macOS is 104 bytes including the NUL terminator → max 103 usable bytes
        let maxSunPathBytes = MemoryLayout<sockaddr_un>.size - MemoryLayout<sa_family_t>.size - 1
        guard path.utf8.count <= maxSunPathBytes else {
            NSLog("HookServer: socket path too long (\(path.utf8.count) bytes, max \(maxSunPathBytes)): \(path)")
            return
        }
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
        // Restrict socket to owner only
        chmod(path, 0o600)
        guard Darwin.listen(fd, 32) == 0 else { close(fd); return }

        while true {
            let clientFD = Darwin.accept(fd, nil, nil)
            guard clientFD >= 0 else { break }
            // Reject connections from other users (same-UID check)
            var euid: uid_t = 0
            var egid: gid_t = 0
            guard getpeereid(clientFD, &euid, &egid) == 0, euid == getuid() else {
                close(clientFD)
                continue
            }
            // Enforce concurrent connection ceiling
            connectionLock.lock()
            let count = connectionCount
            if count < Self.maxConnections { connectionCount += 1 }
            connectionLock.unlock()
            guard count < Self.maxConnections else {
                close(clientFD)
                continue
            }
            Thread.detachNewThread { self.handleClient(fd: clientFD) }
        }
    }

    // MARK: - Client handler (background thread)

    private func handleClient(fd: Int32) {
        defer {
            connectionLock.lock(); connectionCount -= 1; connectionLock.unlock()
        }
        // 5-second receive timeout — unresponsive clients don't hold threads forever
        var tv = timeval(tv_sec: Self.receiveTimeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

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
            if raw.count > Self.maxPayload { break }
        }

        guard !raw.isEmpty,
              let payload = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            sendLine(fd: fd, text: #"{"ok":true}"#)
            close(fd)
            return
        }

        let coucouKind = payload["coucou_kind"] as? String ?? ""

        // statusline payloads are handled separately — no session, no reveal, no sound
        if coucouKind == "statusline" {
            Task { @MainActor in self.processStatusLine(payload: payload) }
            sendLine(fd: fd, text: #"{"ok":true}"#)
            close(fd)
            return
        }

        // AskUserQuestion via --ask PreToolUse hook — hold fd open like PermissionRequest
        if coucouKind == "ask_user_question" {
            let toolInput = payload["tool_input"] as? [String: Any] ?? [:]
            if let parsed = AskQuestion.parse(toolInput: toolInput) {
                Task { @MainActor in self.processQuestionRequest(fd: fd, parsed: parsed, payload: payload) }
            } else {
                // Malformed payload — fall back: send ask so Claude Code re-asks in terminal
                sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#)
                close(fd)
            }
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
    // Claude Code events route to the permanent "integration_claude" task.
    // Events tagged with a valid coucou_agent route to a dynamic "integration_<agent>" task.
    // View switches only happen if VS Code (or the agent pill) is currently focused.
    // When not focused: state updates animate the mini bot in the pill; badge shown for alerts.

    @MainActor
    private func processEvent(name: String, payload: [String: Any]) {
        let state = AppState.shared
        let sessionId = payload["session_id"] as? String
                     ?? payload["conversation_id"] as? String
                     ?? "unknown"
        let cwd = payload["cwd"] as? String ?? ""
        let rawName = URL(fileURLWithPath: cwd).lastPathComponent
        let projectName = aliasProjectName(rawName.isEmpty ? "Session" : rawName)

        // Determine which pill this event belongs to.
        // coucou_agent must be lowercase, digits and hyphens, ≤ 24 chars.
        let rawAgent = payload["coucou_agent"] as? String ?? ""
        let validAgent = Self.validateAgent(rawAgent)

        let termProgram = payload["term_program"] as? String ?? ""
        let bundleId    = payload["bundle_id"]    as? String ?? ""

        // Cursor identified solely by its stable Electron bundle ID.
        // ToDesktop builds other apps too — do not match on "todesktop" alone.
        let isCursorEditor = bundleId.lowercased() == "com.todesktop.230313mzl4w4u92"
        let isVSCodeEditor = !isCursorEditor && (
            termProgram.lowercased().contains("vscode") ||
            bundleId.lowercased().contains("vscode"))

        // Routing:
        // • "codex" → agent_codex (GitHub build only: workspace pill, approvals in the notch)
        // • other valid coucou_agent → external pill (fire-and-forget, no approval card)
        // • Cursor bundle ID → agent_cursor
        // • VS Code → integration_claude
        // • a known terminal (Warp, Terminal, iTerm…) → integration_claude, host recorded on the task
        #if !APPSTORE
        let isCodexEvent = rawAgent == "codex"
        #else
        let isCodexEvent = false
        #endif
        let agentId: String
        let isExternalAgent: Bool
        var hostApp: String? = nil
        if isCodexEvent {
            agentId = "agent_codex"
            isExternalAgent = false
        } else if let agent = validAgent {
            agentId = "agent_\(agent)"
            isExternalAgent = true
        } else if isCursorEditor {
            agentId = "agent_cursor"
            isExternalAgent = false
        } else if isVSCodeEditor {
            agentId = "integration_claude"
            isExternalAgent = false
        } else if let host = ClaudeHost.terminal(termProgram: termProgram, bundleId: bundleId) {
            agentId = "integration_claude"
            isExternalAgent = false
            hostApp = host.bundleId
        } else {
            nbLog("Ignored \(name) from \(termProgram.isEmpty ? bundleId : termProgram) (\(projectName))")
            return
        }

        let focused = state.focusId == agentId
        // For sessions that carry no id, derive a unique key from pill + cwd so that
        // concurrent anonymous sessions are tracked independently in RecapStore.
        let recapSessionId = (sessionId == "unknown" || sessionId.isEmpty)
            ? "\(agentId)+\(cwd)"
            : sessionId

        #if PHONE_LINK
        // The iPhone's "last turn" (prompt, actions, diffs, answer).
        if !isExternalAgent { TurnRecorder.shared.record(event: name, payload: payload, pillId: agentId) }
        #endif

        // While a permission request is pending, dismiss when the resolving event arrives,
        // then continue normal processing. Only skip normal processing when unresolved.
        if let pending = state.pendingApproval, agentId == pending.pillId,
           pending.sessionId != "demo_session" {
            let handledNote: String
            switch pending.pillId {
            case "agent_cursor":  handledNote = "Handled in Cursor."
            case "agent_codex":   handledNote = "Handled in Codex."
            case "agent_copilot": handledNote = "Handled in Copilot CLI."
            case "agent_muse":    handledNote = "Handled in Muse Code."
            case "agent_hermes":  handledNote = "Handled in Hermes."
            default:              handledNote = "Handled in \(claudeHostName)."
            }
            var resolved = false
            switch name {
            case "PostToolUse", "PostToolUseFailure":
                // Only dismiss when this exact tool call finished — same session, tool and input.
                // Other parallel tools finishing must not close the card.
                if sessionId == pending.sessionId,
                   (payload["tool_name"] as? String ?? "") == pending.tool,
                   Self.approvalInputKey(payload["tool_input"] as? [String: Any] ?? [:]) == pending.inputKey {
                    dismissApprovalCard(note: handledNote)
                    resolved = true
                }
            case "Stop", "StopFailure", "UserPromptSubmit", "SessionEnd", "Interrupt":
                // Turn ended or session interrupted — the permission is moot.
                if sessionId == pending.sessionId {
                    dismissApprovalCard(note: handledNote)
                    resolved = true
                }
            default: break
            }
            if !resolved { return }
            // Approval dismissed — fall through so the resolving event updates state normally.
        }

        if !isExternalAgent && !isCodexEvent {
            recordCode(event: name, pillId: agentId, payload: payload, cwd: cwd, project: projectName)
        }

        switch name {

        case "SessionStart":
            activeSessionId = sessionId
            if isExternalAgent { upsertExternalAgent(id: agentId, name: validAgent!) } else { upsertWorkspaceTask(id: agentId, projectName: projectName, cwd: cwd, hostApp: hostApp, bundleId: bundleId) }
            if let idx = state.tasks.firstIndex(where: { $0.id == agentId }) { state.tasks[idx].finalLine = nil }
            nbLog("SessionStart \(isExternalAgent ? agentId : projectName) (\(sessionId.prefix(8)))")
            NotificationCenter.default.post(name: .checkMondayRecap, object: nil)
            if state.isPresent { expandIfNeeded(to: .overview) }
            SoundEngine.shared.play("work")
            if agentId == "agent_hermes", let platform = payload["platform"] as? String,
               !platform.isEmpty, platform != "cli" {
                let capitalized = platform.prefix(1).uppercased() + platform.dropFirst()
                appendStep(id: agentId, step: String(capitalized))
            }

        case "UserPromptSubmit":
            activeSessionId = sessionId
            if isExternalAgent { upsertExternalAgent(id: agentId, name: validAgent!) } else { upsertWorkspaceTask(id: agentId, projectName: projectName, cwd: cwd, hostApp: hostApp, bundleId: bundleId) }
            if let idx = state.tasks.firstIndex(where: { $0.id == agentId }) { state.tasks[idx].finalLine = nil }
            state.updateTask(id: agentId, state: .thinking)
            if let prompt = payload["prompt"] as? String, !prompt.isEmpty {
                appendStep(id: agentId, step: String(prompt.prefix(60)))
            }
            RecapStore.shared.userPromptSubmit(sessionId: recapSessionId, pillId: agentId, project: projectName)
            NotificationCenter.default.post(name: .checkMondayRecap, object: nil)
            if state.isPresent { expandIfNeeded(to: .overview) }

        case "PreToolUse":
            activeSessionId = sessionId
            let tool = payload["tool_name"] as? String ?? "Tool"
            if let idx = state.tasks.firstIndex(where: { $0.id == agentId }) { state.tasks[idx].finalLine = nil }
            RecapStore.shared.preToolUse(sessionId: recapSessionId, tool: tool)
            // AskUserQuestion is handled via the dedicated --ask hook.
            // Skip state/step update here to avoid flickering over the question card.
            guard tool != "AskUserQuestion" else { break }
            if isExternalAgent { upsertExternalAgent(id: agentId, name: validAgent!) } else { upsertWorkspaceTask(id: agentId, projectName: projectName, cwd: cwd, hostApp: hostApp, bundleId: bundleId) }
            state.updateTask(id: agentId, state: .working)
            let input = payload["tool_input"] as? [String: Any] ?? [:]
            let step = localizedStep(tool: tool, input: input)
            appendStep(id: agentId, step: step)
            nbLog("PreToolUse \(tool)")

        case "PostToolUse":
            state.updateTask(id: agentId, state: .working)
            // Live diff for Edit / MultiEdit / Write
            let diffTool = payload["tool_name"] as? String ?? ""
            let diffInput = payload["tool_input"] as? [String: Any] ?? [:]
            if let diff = buildFileDiff(tool: diffTool, input: diffInput, pillId: agentId) {
                let idx = state.appendSessionDiff(diff, for: agentId)
                let step = String.makeDiffStep(filename: diff.name, added: diff.added, removed: diff.removed, diffId: idx)
                appendStep(id: agentId, step: step)
                RecapStore.shared.recordFileDiff(sessionId: recapSessionId, path: diff.name, added: diff.added, removed: diff.removed)
            }

        case "PostToolUseFailure":
            state.updateTask(id: agentId, state: .working)
            appendStep(id: agentId, step: "⚠ failed")

        case "Notification":
            let message = payload["message"] as? String ?? ""
            let lower = message.lowercased()
            if lower.contains("rate limit") || lower.contains("limite d") {
                state.updateTask(id: agentId, state: .ratelimit)
                SoundEngine.shared.play("rate")
            } else if message.hasSuffix("?") {
                state.updateTask(id: agentId, state: .question)
                appendStep(id: agentId, step: message)
            }

        case "Stop":
            state.updateTask(id: agentId, state: .finished)
            let rawFinal = (payload["last_assistant_message"] as? String)
                ?? (payload["message"] as? String) ?? ""
            let finalText = DiffEngine.toOneLine(rawFinal)
            if !finalText.isEmpty {
                appendStep(id: agentId, step: finalText)
                if let idx = state.tasks.firstIndex(where: { $0.id == agentId }) {
                    state.tasks[idx].finalLine = finalText
                }
            }
            RecapStore.shared.stop(sessionId: recapSessionId)
            SoundEngine.shared.play("finish")
            if focused {
                expandIfNeeded(to: .finished)
            } else {
                setPillBadge(id: agentId, badge: .finished)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) {
                if isExternalAgent {
                    AppState.shared.removeTask(id: agentId)
                } else {
                    AppState.shared.updateTask(id: agentId, state: .idle)
                    self.clearPillBadge(id: agentId)
                }
            }

        case "StopFailure":
            RecapStore.shared.stop(sessionId: recapSessionId)
            state.updateTask(id: agentId, state: .error)
            SoundEngine.shared.play("error")
            if focused {
                expandIfNeeded(to: .error)
            } else {
                setPillBadge(id: agentId, badge: .error)
            }

        case "Interrupt":
            // Codex: user stopped the turn
            RecapStore.shared.stop(sessionId: recapSessionId)
            activeSessionId = nil
            state.updateTask(id: agentId, state: .idle)
            clearPillBadge(id: agentId)

        case "SessionEnd":
            activeSessionId = nil
            if let idx = state.tasks.firstIndex(where: { $0.id == agentId }) { state.tasks[idx].finalLine = nil }
            state.clearSessionDiffs(for: agentId)
            state.removeTask(id: agentId)
            RecapStore.shared.sessionEnd(sessionId: recapSessionId)

        case "SubagentStart":
            appendStep(id: agentId, step: "+ subagent")

        case "SubagentStop":
            appendStep(id: agentId, step: "• subagent done")

        default:
            break
        }
    }

    // MARK: - Agent validation + dynamic pill

    /// Validates a coucou_agent name: lowercase, digits and hyphens, 1–24 chars.
    /// "claude" is reserved and rejected so it cannot impersonate the Claude Code pill.
    /// Returns the name unchanged if valid, nil otherwise.
    private static func validateAgent(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.count <= 24, raw != "claude" else { return nil }
        for scalar in raw.unicodeScalars {
            let v = scalar.value
            let ok = (v >= 0x61 && v <= 0x7A)  // a-z
                  || (v >= 0x30 && v <= 0x39)   // 0-9
                  || v == 0x2D                   // -
            guard ok else { return nil }
        }
        return raw
    }

    /// Creates a dynamic pill for a third-party agent on first event, then no-ops.
    /// ID format: "agent_<name>" — never collides with "integration_*" pills.
    /// Inserted right after integration_claude so it appears in the visible prefix(4).
    @MainActor
    private func upsertExternalAgent(id: String, name: String) {
        let state = AppState.shared
        guard state.tasks.firstIndex(where: { $0.id == id }) == nil else { return }
        let color: String
        if let def = PillCatalog.definition(for: id) {
            color = def.color
        } else {
            color = IslandConst.colorForProject(name)
        }
        let task = AgentTask(id: id, name: name, color: color, state: .idle, steps: [], source: .agent)
        if let claudeIdx = state.tasks.firstIndex(where: { $0.id == "integration_claude" }) {
            state.tasks.insert(task, at: claudeIdx + 1)
        } else {
            state.tasks.append(task)
        }
        if state.focusId == nil { state.focusId = id }
        state.syncMode()
    }

    // MARK: - Helpers

    @MainActor
    private func expandIfNeeded(to view: IslandView) {
        let state = AppState.shared
        let isAlert: Bool
        switch view {
        case .approval, .question, .finished, .error, .confused: isAlert = true
        default: isAlert = false
        }
        if state.mode == .expanded {
            // Approval and question always win; other alerts are blocked while a card is showing
            if view == .approval || view == .question {
                state.view = view
            } else if isAlert && state.pendingApproval == nil {
                state.view = view
            }
        } else if isAlert {
            // Alerts always force-expand
            NotificationCenter.default.post(name: .hookExpand, object: view)
        } else if state.mode == .hidden {
            // Non-alert work events: reveal compact only, never force-expand
            NotificationCenter.default.post(name: .hookReveal, object: nil)
        }
        // Already compact and non-alert: Mochi state update is enough, no expand
    }

    // MARK: - Status line (plan gauge)

    @MainActor
    private func processStatusLine(payload: [String: Any]) {
        if let usage = ClaudePlanGauge.parse(payload: payload) {
            AppState.shared.claudePlanUsage = usage
        }
    }

    // MARK: - Permission request (blocking — Claude Code waits for decision)

    @MainActor
    private func processPermissionRequest(fd: Int32, payload: [String: Any]) {
        let state = AppState.shared
        let sessionId = payload["session_id"] as? String
                     ?? payload["conversation_id"] as? String
                     ?? "unknown"
        let cwd       = payload["cwd"]        as? String ?? ""
        let rawName   = URL(fileURLWithPath: cwd).lastPathComponent
        let projectName = aliasProjectName(rawName.isEmpty ? "Session" : rawName)

        let rawAgent = payload["coucou_agent"] as? String ?? ""
        let termProgram = payload["term_program"] as? String ?? ""
        let bundleId    = payload["bundle_id"]    as? String ?? ""
        let isCursorEditor = bundleId.lowercased() == "com.todesktop.230313mzl4w4u92"
        let isVSCodeEditor = !isCursorEditor && (
            termProgram.lowercased().contains("vscode") ||
            bundleId.lowercased().contains("vscode"))

        // Codex, Copilot CLI and Muse Code get the same approval card as Claude Code / Cursor.
        // Other external agents (any other coucou_agent) answer immediately with "ask"
        // so the agent re-asks in its own terminal — they do not get a notch card.
        #if !APPSTORE
        let isCodexRequest   = rawAgent == "codex"
        let isCopilotRequest = rawAgent == "copilot"
        let isMuseRequest    = rawAgent == "muse"
        // isHermesRequest is true only when the plugin sent coucou_has_transport: true,
        // meaning register_approval_transport is wired and Hermes will honour our choice.
        // Without that flag the request falls through to "ask" so Hermes handles it natively.
        let isHermesRequest  = rawAgent == "hermes"
            && UserDefaults.standard.bool(forKey: "hermesApprovalsEnabled")
            && (payload["coucou_has_transport"] as? Bool == true)
        #else
        let isCodexRequest   = false
        let isCopilotRequest = false
        let isMuseRequest    = false
        let isHermesRequest  = false
        #endif
        if !isCodexRequest && !isCopilotRequest && !isMuseRequest && !isHermesRequest && Self.validateAgent(rawAgent) != nil {
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#)
                close(fd)
            }
            return
        }

        // Determine which workspace pill owns the request.
        let pillId: String
        if isCodexRequest {
            pillId = "agent_codex"
        } else if isCopilotRequest {
            pillId = "agent_copilot"
        } else if isMuseRequest {
            pillId = "agent_muse"
        } else if isHermesRequest {
            pillId = "agent_hermes"
        } else if isCursorEditor {
            pillId = "agent_cursor"
        } else {
            pillId = "integration_claude"
        }
        // Terminal sessions: only when turned on in Settings, else the terminal asks itself.
        let terminalHost = isCursorEditor || isVSCodeEditor ? nil
            : ClaudeHost.terminal(termProgram: termProgram, bundleId: bundleId)
        let isTerminal = terminalHost != nil && ClaudeHost.terminalCardsEnabled
        guard isCodexRequest || isCopilotRequest || isMuseRequest || isHermesRequest || isCursorEditor || isVSCodeEditor || isTerminal else {
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#)
                close(fd)
            }
            return
        }

        let tool = payload["tool_name"] as? String ?? "Tool"
        let toolInput = payload["tool_input"] as? [String: Any] ?? [:]
        let inputKey = Self.approvalInputKey(toolInput)
        nbLog("PermissionRequest \(tool) [\(pillId)]")

        // AskUserQuestion is now handled via the dedicated --ask PreToolUse hook.
        // If it still arrives here as a PermissionRequest, reply "ask" so Claude Code
        // re-asks in the terminal — never show the question twice.
        if tool == "AskUserQuestion" {
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#)
                close(fd)
            }
            return
        }

        let command = toolInput["command"] as? String ?? tool

        if pendingApprovalFD >= 0 {
            // Displace the previous request: write "ask" then cancel its source.
            // The cancel handler closes the old fd — never close it directly.
            let old = pendingApprovalFD
            let oldSource = approvalFDSource
            approvalFDSource = nil
            Task.detached { [weak self] in
                // "ask" → nb-hook outputs nothing → Claude Code re-asks
                self?.sendLine(fd: old, text: #"{"permissionDecision":"ask"}"#)
                DispatchQueue.main.async { oldSource?.cancel() }
            }
        }
        pendingApprovalFD = fd
        activeSessionId = sessionId

        upsertWorkspaceTask(id: pillId, projectName: projectName, cwd: cwd, hostApp: terminalHost?.bundleId, bundleId: bundleId)
        state.updateTask(id: pillId, state: .approval)
        state.pendingApproval = ApprovalInfo(sessionId: sessionId, tool: tool,
                                              command: command, inputKey: inputKey, pillId: pillId)
        state.isPinned = true
        SoundEngine.shared.play("approval")

        // Approval always forces the island open — user must be able to respond.
        // Save current focus so we can restore it when the card is dismissed.
        if focusBeforeApproval == nil { focusBeforeApproval = state.focusId }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.focusId = pillId }
        expandIfNeeded(to: .approval)

        // Monitor fd: if the editor closes the connection (handled externally), dismiss the card.
        // The cancel handler closes the fd — never close it anywhere else.
        let capturedPillId = pillId
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, self.pendingApprovalFD == fd else { return }
            let note: String
            switch capturedPillId {
            case "agent_cursor":  note = "Handled in Cursor."
            case "agent_codex":   note = "Handled in Codex."
            case "agent_copilot": note = "Handled in Copilot CLI."
            case "agent_muse":    note = "Handled in Muse Code."
            case "agent_hermes":  note = "Handled in Hermes."
            default:              note = "Handled in \(self.claudeHostName)."
            }
            self.dismissApprovalCard(note: note)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        approvalFDSource = source

        // Safety timeout — show a note and cancel without sending a decision.
        // nb-hook reads EOF from the cancel handler's close and exits; Claude Code / Codex re-asks.
        // Copilot/Muse use 110s (their relay waits 118s but their hook timeout is 120s, leaving little margin).
        let waitTimeout: Double = (isCopilotRequest || isMuseRequest) ? 110 : 115
        let captured = fd
        DispatchQueue.main.asyncAfter(deadline: .now() + waitTimeout) { [weak self] in
            guard let self, self.pendingApprovalFD == captured else { return }
            let note: String
            switch capturedPillId {
            case "agent_cursor":  note = "Still waiting in Cursor."
            case "agent_codex":   note = "Still waiting in Codex."
            case "agent_copilot": note = "Still waiting in Copilot CLI."
            case "agent_muse":    note = "Still waiting in Muse Code."
            case "agent_hermes":  note = "Still waiting in Hermes."
            default:              note = "Still waiting in \(self.claudeHostName)."
            }
            self.dismissApprovalCard(note: note)
        }
    }

    /// Called by ApprovalView buttons. Writes the decision to the waiting nb-hook and cleans up.
    @MainActor
    func sendApprovalDecision(_ decision: String) {
        // Only intercept a demo card — a real card has a live fd (pendingApprovalFD >= 0).
        if DemoEngine.shared.isActive,
           AppState.shared.pendingApproval?.sessionId == "demo_session",
           pendingApprovalFD < 0 {
            let s = AppState.shared
            s.pendingApproval = nil
            s.isPinned = false
            s.view = s.tasks.isEmpty ? .empty : .overview
            DemoEngine.shared.handleApprovalDecision(decision)
            return
        }
        let fd = pendingApprovalFD
        pendingApprovalFD = -1
        // Capture source before nulling — we send the decision first, then cancel the source.
        // The cancel handler closes the fd; never close it directly.
        let source = approvalFDSource
        approvalFDSource = nil

        let json: String
        switch decision {
        case "allow":  json = #"{"permissionDecision":"allow"}"#
        case "always": json = #"{"permissionDecision":"always"}"#
        case "ask":    json = #"{"permissionDecision":"ask"}"#
        default:       json = #"{"permissionDecision":"deny"}"#
        }

        if fd >= 0 {
            Task.detached { [weak self] in
                // Write decision while fd is still valid, then cancel source → cancel handler closes fd
                self?.sendLine(fd: fd, text: json)
                DispatchQueue.main.async { source?.cancel() }
            }
        } else {
            source?.cancel()
        }

        let state = AppState.shared
        let pillId = state.pendingApproval?.pillId ?? "integration_claude"
        state.pendingApproval = nil
        state.isPinned = false
        RecapStore.shared.recordDecision(pillId: pillId, decision: decision)
        state.updateTask(id: pillId, state: .working)
        clearPillBadge(id: pillId)
        // Restore focus to the pill that was focused before the approval card appeared.
        if let prev = focusBeforeApproval {
            focusBeforeApproval = nil
            if state.focusId == pillId, state.tasks.contains(where: { $0.id == prev }) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.focusId = prev }
            }
        }
        state.view = state.tasks.isEmpty ? .empty : .overview
    }

    // MARK: - Question request

    @MainActor
    private func processQuestionRequest(fd: Int32, parsed: AskQuestion, payload: [String: Any]) {
        let state = AppState.shared
        let sessionId = payload["session_id"] as? String
                     ?? payload["conversation_id"] as? String
                     ?? "unknown"
        let cwd       = payload["cwd"]        as? String ?? ""
        let rawName   = URL(fileURLWithPath: cwd).lastPathComponent
        let projectName = aliasProjectName(rawName.isEmpty ? "Session" : rawName)

        let rawAgent    = payload["coucou_agent"] as? String ?? ""
        let termProgram = payload["term_program"]  as? String ?? ""
        let bundleId    = payload["bundle_id"]     as? String ?? ""
        let isCursorEditor = bundleId.lowercased() == "com.todesktop.230313mzl4w4u92"
        let isVSCodeEditor = !isCursorEditor && (
            termProgram.lowercased().contains("vscode") ||
            bundleId.lowercased().contains("vscode"))
        #if !APPSTORE
        let isCodexRequest = rawAgent == "codex"
        #else
        let isCodexRequest = false
        #endif
        let pillId: String
        if isCodexRequest {
            pillId = "agent_codex"
        } else if isCursorEditor {
            pillId = "agent_cursor"
        } else {
            pillId = "integration_claude"
        }
        // Terminal sessions: only when turned on in Settings, else the terminal asks itself.
        let terminalHost = isCursorEditor || isVSCodeEditor ? nil
            : ClaudeHost.terminal(termProgram: termProgram, bundleId: bundleId)
        let isTerminal = terminalHost != nil && ClaudeHost.terminalCardsEnabled
        guard isCodexRequest || isCursorEditor || isVSCodeEditor || isTerminal else {
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#)
                close(fd)
            }
            return
        }

        // Displace any previous question waiting for an answer.
        if pendingQuestionFD >= 0 {
            let old = pendingQuestionFD
            let oldSrc = questionFDSource
            questionFDSource = nil
            Task.detached { [weak self] in
                self?.sendLine(fd: old, text: #"{"permissionDecision":"ask"}"#)
                DispatchQueue.main.async { oldSrc?.cancel() }
            }
        }
        pendingQuestionFD = fd
        activeSessionId = sessionId
        questionPillId = pillId
        questionSessionId = (sessionId == "unknown" || sessionId.isEmpty)
            ? "\(pillId)+\(cwd)"
            : sessionId

        upsertWorkspaceTask(id: pillId, projectName: projectName, cwd: cwd, hostApp: terminalHost?.bundleId, bundleId: bundleId)
        state.updateTask(id: pillId, state: .question)
        state.pendingQuestion = parsed
        state.isPinned = true
        SoundEngine.shared.play("approval")

        if focusBeforeQuestion == nil { focusBeforeQuestion = state.focusId }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.focusId = pillId }
        expandIfNeeded(to: .question)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, self.pendingQuestionFD == fd else { return }
            self.dismissQuestionCard(note: "")
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        questionFDSource = source

        let captured = fd
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            guard let self, self.pendingQuestionFD == captured else { return }
            // Send "ask" so nb-hook exits cleanly; Claude Code re-asks in terminal.
            let askFD = self.pendingQuestionFD
            self.pendingQuestionFD = -1
            let src = self.questionFDSource
            self.questionFDSource = nil
            Task.detached { [weak self] in
                self?.sendLine(fd: askFD, text: #"{"permissionDecision":"ask"}"#)
                DispatchQueue.main.async { src?.cancel() }
            }
            self.dismissQuestionCard(note: "")
        }
    }

    /// "VS Code", "Warp"… — where the Claude Code pill's current session runs.
    @MainActor
    private var claudeHostName: String {
        ClaudeHost.name(for: AppState.shared.tasks.first { $0.id == "integration_claude" }?.hostApp)
    }

    /// Updates or transiently creates a workspace pill (VS Code or Cursor) task.
    /// If the task already exists (persistent), just updates name/cwd.
    /// If missing (transient), creates it and inserts after the main pill.
    @MainActor
    private func upsertWorkspaceTask(id: String, projectName: String, cwd: String = "", hostApp: String? = nil, bundleId: String = "") {
        let state = AppState.shared
        if let idx = state.tasks.firstIndex(where: { $0.id == id }) {
            state.tasks[idx].name = projectName
            if !cwd.isEmpty { state.tasks[idx].sessionCwd = cwd }
            if id == "integration_claude" { state.tasks[idx].hostApp = hostApp }
            if !bundleId.isEmpty { state.tasks[idx].sessionBundleId = bundleId }
            return
        }
        // Transient: create and insert after the main pill
        let def = PillCatalog.definition(for: id)
        let color = def?.color ?? "#C0C4CC"
        let source = def?.source ?? .agent
        var task = AgentTask(id: id, name: projectName, color: color,
                             state: .idle, steps: [], source: source, isIntegration: true)
        if id == "integration_claude" { task.hostApp = hostApp }
        if !bundleId.isEmpty { task.sessionBundleId = bundleId }
        if let mainIdx = state.tasks.firstIndex(where: { $0.id == state.mainPillId }) {
            state.tasks.insert(task, at: mainIdx + 1)
        } else {
            state.tasks.insert(task, at: 0)
        }
        if state.focusId == nil { state.focusId = id }
        state.syncMode()
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

    @MainActor
    private func appendStep(id: String, step: String) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[idx].steps.append(step)
        if state.tasks[idx].steps.count > 20 { state.tasks[idx].steps.removeFirst() }
        state.tasks[idx].stepIndex = state.tasks[idx].steps.count - 1
    }

    // MARK: - Code view

    /// Keeps what the code view shows of a Claude Code session: phases, last edit, last command.
    @MainActor
    private func recordCode(event: String, pillId: String, payload: [String: Any], cwd: String, project: String) {
        let state = AppState.shared
        if event == "SessionEnd" {
            state.codeSessions[pillId] = nil
            return
        }
        var session = state.codeSessions[pillId] ?? CodeSession(project: project, root: cwd)
        let tool = payload["tool_name"] as? String ?? ""
        switch event {
        case "UserPromptSubmit":
            session = CodeSession(project: project, root: cwd)
        case "PreToolUse":
            session.toolStarted(tool: tool, input: payload["tool_input"] as? [String: Any] ?? [:], cwd: cwd)
        case "PostToolUse", "PostToolUseFailure":
            let failed = event == "PostToolUseFailure"
            session.toolFinished(tool: tool, response: payload["tool_response"], failed: failed, error: payload["error"] as? String)
            // A remote session's files are on its host, not here.
            if !failed, tool == "Edit", payload["coucou_remote"] == nil, let edit = session.edit, !edit.added.isEmpty {
                loadSnippet(edit, pillId: pillId, root: session.root, cwd: cwd)
            }
        case "Stop":
            session.endTurn()
        default:
            return
        }
        state.codeSessions[pillId] = session
    }

    /// Reads the lines around an edit off the main thread, then adds them if the edit is still the one shown.
    @MainActor
    private func loadSnippet(_ edit: CodeEdit, pillId: String, root: String, cwd: String) {
        let base = edit.path.hasPrefix(root + "/") ? root : cwd
        DispatchQueue.global(qos: .utility).async {
            guard let snippet = CodeView.readSnippet(path: edit.path, root: base, find: edit.added) else { return }
            Task { @MainActor in
                let state = AppState.shared
                guard state.codeSessions[pillId]?.edit == edit else { return }
                state.codeSessions[pillId]?.edit?.snippet = snippet
            }
        }
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

    // MARK: - Localized step labels

    private func localizedStep(tool: String, input: [String: Any]) -> String {
        let labels: [String: String] = [
            "Bash":         String(localized: "step.runs",       defaultValue: "Runs"),
            "Read":         String(localized: "step.reads",      defaultValue: "Reads"),
            "Write":        String(localized: "step.writes",     defaultValue: "Writes"),
            "Edit":         String(localized: "step.edits",      defaultValue: "Edits"),
            "Glob":         String(localized: "step.searches",   defaultValue: "Searches"),
            "Grep":         String(localized: "step.searches",   defaultValue: "Searches"),
            "WebSearch":    String(localized: "step.web-search", defaultValue: "Searches the web"),
            "WebFetch":     String(localized: "step.fetches",    defaultValue: "Fetches"),
            "TodoWrite":    String(localized: "step.tasks",      defaultValue: "Tasks"),
            "Task":         String(localized: "step.agent",      defaultValue: "Agent"),
            "LS":           String(localized: "step.lists",      defaultValue: "Lists"),
            "MultiEdit":    String(localized: "step.edits",      defaultValue: "Edits"),
            "NotebookEdit": String(localized: "step.notebook",   defaultValue: "Notebook"),
            // Codex tools
            "apply_patch":  String(localized: "step.edits",     defaultValue: "Edits"),
            "update_plan":  String(localized: "step.tasks",     defaultValue: "Tasks"),
            "spawn_agent":  String(localized: "step.agent",     defaultValue: "Agent"),
        ]
        var label = labels[tool] ?? tool

        // Codex MCP tools arrive as mcp__server__tool — show "server · tool"
        if tool.hasPrefix("mcp__") {
            let rest = String(tool.dropFirst(5))
            let parts = rest.components(separatedBy: "__")
            label = parts.count >= 2 ? "\(parts[0]) · \(parts.dropFirst().joined(separator: "__"))" : rest
        }

        // Bash: infer a more precise verb from the command
        if tool == "Bash", let cmd = input["command"] as? String {
            return "\(bashVerb(cmd)) · \(oneLine(cmd))"
        }

        // apply_patch: extract the first file name from the patch
        if tool == "apply_patch", let patch = input["command"] as? String {
            for line in patch.split(separator: "\n") {
                for prefix in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] {
                    if line.hasPrefix(prefix) {
                        let path = String(line.dropFirst(prefix.count))
                        return "\(label) · \(URL(fileURLWithPath: path).lastPathComponent)"
                    }
                }
            }
            return label
        }

        if let cmd = input["command"] as? String {
            return "\(label) · \(oneLine(cmd))"
        } else if let path = input["path"] as? String {
            return "\(label) · \(URL(fileURLWithPath: path).lastPathComponent)"
        } else if let file = input["file_path"] as? String {
            return "\(label) · \(URL(fileURLWithPath: file).lastPathComponent)"
        } else if let query = input["query"] as? String {
            return "\(label) · \(oneLine(query))"
        }
        return label
    }

    /// Infers a localized verb from a shell command's first word.
    private func bashVerb(_ command: String) -> String {
        let first = command.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        switch first {
        case "cat", "bat", "head", "tail", "less", "more", "nl": return String(localized: "step.reads",    defaultValue: "Reads")
        case "rg", "grep", "find", "fd", "ls", "tree", "wc":    return String(localized: "step.searches", defaultValue: "Searches")
        default: break
        }
        let testRunners = ["pytest", "vitest", "jest", "npm test", "npm run test",
                           "cargo test", "go test", "swift test", "make test",
                           "xcodebuild test", "unittest"]
        if testRunners.contains(where: { command.contains($0) }) { return String(localized: "step.tests", defaultValue: "Tests") }
        return String(localized: "step.runs", defaultValue: "Runs")
    }

    // MARK: - Live diff helpers

    @MainActor
    private func buildFileDiff(tool: String, input: [String: Any], pillId: String) -> FileDiff? {
        switch tool {
        case "Edit":
            guard let old = input["old_string"] as? String,
                  let new = input["new_string"] as? String,
                  let path = input["file_path"] as? String,
                  !old.isEmpty || !new.isEmpty else { return nil }
            let d = DiffEngine.fromEdit(old: old, new: new, path: path)
            return (d.added > 0 || d.removed > 0) ? d : nil

        case "MultiEdit":
            guard let path = input["file_path"] as? String,
                  let edits = input["edits"] as? [[String: Any]], !edits.isEmpty else { return nil }
            var totalAdded = 0, totalRemoved = 0, allHunks: [DiffHunk] = [], anyLarge = false
            for edit in edits {
                guard let old = edit["old_string"] as? String,
                      let new = edit["new_string"] as? String else { continue }
                let d = DiffEngine.fromEdit(old: old, new: new, path: path)
                totalAdded += d.added; totalRemoved += d.removed
                allHunks.append(contentsOf: d.hunks); if d.tooLarge { anyLarge = true }
            }
            guard totalAdded > 0 || totalRemoved > 0 else { return nil }
            return FileDiff(path: path, added: totalAdded, removed: totalRemoved,
                            hunks: allHunks, tooLarge: anyLarge, isNewFile: false)

        case "Write":
            guard let path = input["file_path"] as? String,
                  let content = input["content"] as? String, !content.isEmpty else { return nil }
            let d = DiffEngine.fromNew(content: content, path: path)
            return (d.added > 0 || d.removed > 0) ? d : nil

        default:
            return nil
        }
    }

    /// Collapses whitespace so a multi-line command stays one ticker row.
    private func oneLine(_ text: String, limit: Int = 60) -> String {
        let collapsed = text.split(whereSeparator: { $0.isNewline || $0 == "\t" })
                            .joined(separator: " ")
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
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
        // (requires NSOpenPanel to ~/.claude chosen by the user)
        #else
        let dir = Self.supportDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700 as NSNumber], ofItemAtPath: dir.path)
        // nb-hook: shell wrapper (always exits 0, calls nb-hook.py via python3)
        let wrapperURL = URL(fileURLWithPath: Self.hookScriptPath)
        try? nbHookShellWrapper.write(to: wrapperURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755 as NSNumber], ofItemAtPath: wrapperURL.path)
        // nb-hook.py: Python relay
        let pyURL = wrapperURL.deletingLastPathComponent().appendingPathComponent("nb-hook.py")
        try? nbHookPythonGitHub.write(to: pyURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755 as NSNumber], ofItemAtPath: pyURL.path)
        #endif
    }

    // MARK: - Outdated hook detection

    /// Returns true if settings.json has a Coucou hook that needs updating:
    /// either a PermissionRequest hook with timeout < 120s, or the AskUserQuestion
    /// PreToolUse matcher is missing (requires Claude Code 2.1.85+).
    static func hooksNeedUpdate() -> Bool {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any] else {
            return false
        }
        // Track whether any Coucou hook is installed at all
        var hasCoucouHooks = false

        if let permReqHooks = hooks["PermissionRequest"] as? [[String: Any]] {
            for matcher in permReqHooks {
                if let hookList = matcher["hooks"] as? [[String: Any]] {
                    for hook in hookList {
                        if let cmd = hook["command"] as? String,
                           cmd.contains("NotchBuddy") || cmd.contains("coucou") {
                            hasCoucouHooks = true
                            if let timeout = hook["timeout"] as? Int, timeout < 120 { return true }
                        }
                    }
                }
            }
        }

        // Check that the AskUserQuestion PreToolUse entry exists
        if hasCoucouHooks {
            let preToolHooks = hooks["PreToolUse"] as? [[String: Any]] ?? []
            let hasAskEntry = preToolHooks.contains { m in
                (m["matcher"] as? String) == "AskUserQuestion"
                && (m["hooks"] as? [[String: Any]])?.contains {
                    let cmd = $0["command"] as? String ?? ""
                    return cmd.contains("NotchBuddy") || cmd.contains("coucou")
                } ?? false
            }
            if !hasAskEntry { return true }
        }
        return false
    }

    // MARK: - Claude Code settings.json hook installer

    private var _pendingHooksData: Data?
    /// The bytes of settings.json the pending preview was computed from.
    private var _pendingHooksOriginal: Data?

    /// Returns preview JSON without writing — call writeClaudeHooks() to confirm.
    func previewClaudeHooks() throws -> String {
        let (data, original) = try buildHooksData()
        _pendingHooksData = data
        _pendingHooksOriginal = original
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Writes the hooks to disk (call after user confirms preview).
    /// Refused if settings.json changed since the preview, or cannot be backed up.
    func writeClaudeHooks() throws {
        guard let data = _pendingHooksData else { return }
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        try ClaudeSettingsFile.write(data, to: settingsURL, expecting: _pendingHooksOriginal)
        _pendingHooksData = nil
        _pendingHooksOriginal = nil
    }

    private func buildHooksData() throws -> (data: Data, original: Data?) {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        // Unreadable or invalid settings must stop here, never count as empty.
        let snapshot = try ClaudeSettingsFile.read(at: settingsURL)
        var settings = snapshot.object
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
        // "hooks" in a shape we do not know is refused, never replaced.
        var hooks = try ClaudeSettingsFile.hooks(in: settings, name: "settings.json")
        for (event, timeout) in events {
            var existing = try ClaudeSettingsFile.hookGroups(in: hooks, event: event, name: "settings.json")
            existing.removeAll { ($0["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String)?.contains("NotchBuddy") == true || ($0["command"] as? String)?.contains("coucou") == true } ?? false }
            existing.append(["hooks": [["type": "command", "command": quotedCmd, "timeout": timeout]]])
            hooks[event] = existing
        }
        // Dedicated AskUserQuestion PreToolUse hook (Claude Code 2.1.85+, timeout 130s)
        var preToolUse = hooks["PreToolUse"] as? [[String: Any]] ?? []
        preToolUse.append([
            "matcher": "AskUserQuestion",
            "hooks": [["type": "command", "command": "\(quotedCmd) --ask", "timeout": 130]],
        ])
        hooks["PreToolUse"] = preToolUse
        settings["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        return (data, snapshot.bytes)
    }

    func uninstallClaudeHooks() throws {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        let snapshot = try ClaudeSettingsFile.read(at: settingsURL)
        var settings = snapshot.object
        guard var hooks = settings["hooks"] as? [String: Any] else { return }

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
        try ClaudeSettingsFile.write(newData, to: settingsURL, expecting: snapshot.bytes)
    }

    // MARK: - Claude plan status line installer

    private var statusLinePreviousURL: URL {
        Self.supportDir.appendingPathComponent("statusline-previous.json")
    }

    /// Returns true if our statusLine command is installed in ~/.claude/settings.json.
    static func statusLineInstalled() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: url),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sl = settings["statusLine"] as? [String: Any],
              let cmd = sl["command"] as? String else { return false }
        return cmd.contains("nb-hook")
    }

    private var _pendingStatusLineData: Data?
    /// The bytes of settings.json the pending preview was computed from.
    private var _pendingStatusLineOriginal: Data?
    private var _pendingPreviousData: Data?
    private var _pendingDeletePrevious: Bool = false

    /// Returns a diff string (only the statusLine key: before → after) without writing anything.
    func previewStatusLine(install: Bool) throws -> String {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        // Unreadable or invalid settings must stop here, never count as empty.
        let snapshot = try ClaudeSettingsFile.read(at: settingsURL)
        let settings = snapshot.object
        let hookPath = Self.hookScriptPath
        let quotedPath = hookPath.replacingOccurrences(of: "\"", with: "\\\"")
        let quotedCmd = "\"\(quotedPath)\" --statusline"

        // Reset pending side-effects
        _pendingPreviousData = nil
        _pendingDeletePrevious = false

        let oldSL = settings["statusLine"] as? [String: Any]
        let newSL: [String: Any]?

        if install {
            // Check that Python 3 is available (requires Command Line Tools)
            let clCheck = Process()
            clCheck.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
            clCheck.arguments = ["-p"]
            clCheck.standardOutput = FileHandle.nullDevice
            clCheck.standardError = FileHandle.nullDevice
            try? clCheck.run()
            clCheck.waitUntilExit()
            if clCheck.terminationStatus != 0 {
                throw NSError(domain: "Coucou", code: 1,
                              userInfo: [NSLocalizedDescriptionKey:
                                  "Command Line Tools are required but not installed. Run: xcode-select --install"])
            }

            if let existing = oldSL,
               let cmd = existing["command"] as? String, !cmd.contains("nb-hook") {
                // Keep existing object but swap command; save old for later restoration
                var updated = existing
                updated["command"] = quotedCmd
                newSL = updated
                _pendingPreviousData = try? JSONSerialization.data(withJSONObject: existing,
                                                                   options: [.prettyPrinted, .sortedKeys])
            } else if let existing = oldSL,
                      let cmd = existing["command"] as? String, cmd.contains("nb-hook") {
                // Already installed — rebuild to update path if needed, keep other fields
                var updated = existing
                updated["command"] = quotedCmd
                newSL = updated
            } else {
                newSL = ["type": "command", "command": quotedCmd]
            }
        } else {
            // Uninstall: only if it's ours
            if let cur = oldSL, let cmd = cur["command"] as? String, cmd.contains("nb-hook") {
                if let prevData = try? Data(contentsOf: statusLinePreviousURL),
                   let prevObj = (try? JSONSerialization.jsonObject(with: prevData)) as? [String: Any] {
                    newSL = prevObj
                    _pendingDeletePrevious = true
                } else {
                    newSL = nil
                }
            } else {
                newSL = oldSL  // not ours — leave unchanged
            }
        }

        // Build the full settings.json with the new statusLine
        var newSettings = settings
        if let sl = newSL {
            newSettings["statusLine"] = sl
        } else {
            newSettings.removeValue(forKey: "statusLine")
        }
        let data = try JSONSerialization.data(withJSONObject: newSettings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        _pendingStatusLineData = data
        _pendingStatusLineOriginal = snapshot.bytes

        // Build a compact diff: show only the statusLine key before → after
        func slJSON(_ val: [String: Any]?) throws -> String {
            guard let v = val else { return "(none)" }
            let d = try JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys])
            return String(data: d, encoding: .utf8) ?? "(none)"
        }
        let before = try slJSON(oldSL)
        let after  = try slJSON(newSL)
        return "statusLine\nBefore:\n\(before)\n\nAfter:\n\(after)"
    }

    /// Writes settings.json and commits side effects (call after user confirms).
    func writeStatusLine() throws {
        guard let data = _pendingStatusLineData else { return }
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        try ClaudeSettingsFile.write(data, to: settingsURL, expecting: _pendingStatusLineOriginal)
        // Commit side effects only after successful write
        if let prevData = _pendingPreviousData {
            try? prevData.write(to: statusLinePreviousURL, options: .atomic)
        }
        if _pendingDeletePrevious {
            try? FileManager.default.removeItem(at: statusLinePreviousURL)
        }
        _pendingStatusLineData = nil
        _pendingStatusLineOriginal = nil
        _pendingPreviousData = nil
        _pendingDeletePrevious = false
    }

    // MARK: - App Store: hooks via security-scoped bookmark

    #if APPSTORE
    /// Writes nb-hook script and updates settings.json in one shot.
    /// claudeURL must be a URL from NSOpenPanel (sandbox access is granted immediately — no security scope needed).
    func installAndWriteClaudeHooksAppStore(claudeURL: URL) throws {
        let (data, original) = try buildHooksData(claudeURL: claudeURL)

        // Write nb-hook (shell wrapper) + nb-hook.py (Python relay) into ~/.claude/coucou/
        let coucouDir = claudeURL.appendingPathComponent("coucou")
        try FileManager.default.createDirectory(at: coucouDir, withIntermediateDirectories: true)
        let wrapperURL = coucouDir.appendingPathComponent("nb-hook")
        try nbHookShellWrapper.write(to: wrapperURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755 as NSNumber], ofItemAtPath: wrapperURL.path)
        let pyURL = coucouDir.appendingPathComponent("nb-hook.py")
        try nbHookPythonAppStore.write(to: pyURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755 as NSNumber], ofItemAtPath: pyURL.path)

        // Write settings.json (with backup)
        let settingsURL = claudeURL.appendingPathComponent("settings.json")
        try ClaudeSettingsFile.write(data, to: settingsURL, expecting: original)
        UserDefaults.standard.set(true, forKey: "coucouHooksInstalled")
    }

    func uninstallClaudeHooksAppStore(claudeURL: URL) throws {
        let settingsURL = claudeURL.appendingPathComponent("settings.json")
        let snapshot = try ClaudeSettingsFile.read(at: settingsURL)
        var settings = snapshot.object
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
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
        try ClaudeSettingsFile.write(newData, to: settingsURL, expecting: snapshot.bytes)
        UserDefaults.standard.set(false, forKey: "coucouHooksInstalled")
    }

    private func buildHooksData(claudeURL: URL) throws -> (data: Data, original: Data?) {
        let settingsURL = claudeURL.appendingPathComponent("settings.json")
        // Unreadable or invalid settings must stop here, never count as empty.
        let snapshot = try ClaudeSettingsFile.read(at: settingsURL)
        var settings = snapshot.object
        // Derive hook path from the panel-selected claudeURL (real ~/.claude, not container)
        let hookPath = claudeURL.appendingPathComponent("coucou/nb-hook").path
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
        // "hooks" in a shape we do not know is refused, never replaced.
        var hooks = try ClaudeSettingsFile.hooks(in: settings, name: "settings.json")
        for (event, timeout) in events {
            var existing = try ClaudeSettingsFile.hookGroups(in: hooks, event: event, name: "settings.json")
            existing.removeAll { ($0["hooks"] as? [[String: Any]])?.contains {
                ($0["command"] as? String)?.contains("coucou") == true ||
                ($0["command"] as? String)?.contains("NotchBuddy") == true
            } ?? false }
            existing.append(["hooks": [["type": "command", "command": quotedCmd, "timeout": timeout]]])
            hooks[event] = existing
        }
        // Dedicated AskUserQuestion PreToolUse hook (Claude Code 2.1.85+, timeout 130s)
        var preToolUse = hooks["PreToolUse"] as? [[String: Any]] ?? []
        preToolUse.append([
            "matcher": "AskUserQuestion",
            "hooks": [["type": "command", "command": "\(quotedCmd) --ask", "timeout": 130]],
        ])
        hooks["PreToolUse"] = preToolUse
        settings["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        return (data, snapshot.bytes)
    }
    #endif

    // MARK: - Claude Code installed-state detection (both builds)

    /// True when ~/.claude/settings.json already routes Claude Code events to Coucou.
    /// Cursor sessions ride on these same hooks, so they share this state.
    static func claudeHooksInstalled() -> Bool {
        #if APPSTORE
        // Sandboxed: can't read ~/.claude directly — check the install flag set on write.
        return UserDefaults.standard.bool(forKey: "coucouHooksInstalled")
        #else
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        return coucouHooksPresent(inSettings: json)
        #endif
    }

    // MARK: - Gemini CLI and Antigravity hook installers  (#if !APPSTORE only)

    #if !APPSTORE
    private static var geminiSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/settings.json")
    }
    private static var agyHooksURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/config/hooks.json")
    }

    // MARK: Installed-state detection

    static func geminiHooksInstalled() -> Bool {
        guard let data = try? Data(contentsOf: geminiSettingsURL),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any] else { return false }
        for value in hooks.values {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                if let innerHooks = group["hooks"] as? [[String: Any]] {
                    for hook in innerHooks {
                        if let cmd = hook["command"] as? String,
                           cmd.contains("nb-hook"), cmd.contains("--agent gemini") { return true }
                    }
                }
                // Legacy flat entry
                if let cmd = group["command"] as? String,
                   cmd.contains("nb-hook"), cmd.contains("--agent gemini") { return true }
            }
        }
        return false
    }

    static func agyHooksInstalled() -> Bool {
        guard let data = try? Data(contentsOf: agyHooksURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let coucou = root["coucou"] else { return false }
        let json = (try? JSONSerialization.data(withJSONObject: coucou))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return json.contains("nb-hook")
    }

    // MARK: Gemini CLI – preview / write

    private var _pendingGeminiData: Data?
    private var _pendingGeminiFingerprint: String?

    func previewGeminiHooks(install: Bool) throws -> String {
        let url = Self.geminiSettingsURL
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !install && !exists {
            throw NSError(domain: "CoucouNoop", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "No Gemini CLI hooks to remove."
            ])
        }
        let current = exists ? try Data(contentsOf: url) : Data()
        _pendingGeminiFingerprint = sha256Hex(current)
        let newData = install ? try buildGeminiHooksData() : try withoutGeminiHooks()
        _pendingGeminiData = newData
        return String(data: newData, encoding: .utf8) ?? ""
    }

    func writeGeminiHooks() throws {
        guard let data = _pendingGeminiData, let fp = _pendingGeminiFingerprint else { return }
        let url = Self.geminiSettingsURL
        let current = (try? Data(contentsOf: url)) ?? Data()
        guard sha256Hex(current) == fp else {
            throw NSError(domain: "Coucou", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "~/.gemini/settings.json changed since preview. Refresh and try again."
            ])
        }
        try writeJSONFile(data, to: url, suffix: "settings.json")
        _pendingGeminiData = nil
        _pendingGeminiFingerprint = nil
    }

    private func buildGeminiHooksData() throws -> Data {
        var settings = try Self.strictReadJSONObject(at: Self.geminiSettingsURL,
                                                     label: "~/.gemini/settings.json")
        if let raw = settings["hooks"], !(raw is [String: Any]) {
            throw NSError(domain: "Coucou", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "~/.gemini/settings.json: \"hooks\" has an unexpected type — Coucou has not touched it."
            ])
        }
        let base = hookBase()
        // (Gemini event key, normalized event name passed via argv, timeout in ms)
        let events: [(String, String, Int)] = [
            ("SessionStart", "SessionStart", 10000),
            ("SessionEnd",   "SessionEnd",   10000),
            ("BeforeTool",   "PreToolUse",   5000),
            ("AfterTool",    "PostToolUse",  5000),
            ("BeforeAgent",  "UserPromptSubmit", 5000),
            ("AfterAgent",   "Stop",         5000),
        ]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (geminiEvent, normalizedEvent, timeout) in events {
            if let raw = hooks[geminiEvent], !(raw is [[String: Any]]) {
                throw NSError(domain: "Coucou", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "~/.gemini/settings.json: \"hooks\"[\"\(geminiEvent)\"] has an unexpected type — Coucou has not touched it."
                ])
            }
            var groups = hooks[geminiEvent] as? [[String: Any]] ?? []
            // Remove legacy flat entries and groups whose inner hooks contain nb-hook
            groups = removeNbHookEntries(from: groups)
            let hookEntry: [String: Any] = [
                "type": "command",
                "command": "\(base) --agent gemini \(normalizedEvent)",
                "timeout": timeout,
            ]
            groups.append(["matcher": "*", "hooks": [hookEntry]])
            hooks[geminiEvent] = groups
        }
        settings["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: settings,
                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private func withoutGeminiHooks() throws -> Data {
        var settings = try Self.strictReadJSONObject(at: Self.geminiSettingsURL,
                                                     label: "~/.gemini/settings.json")
        if let raw = settings["hooks"], !(raw is [String: Any]) {
            throw NSError(domain: "Coucou", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "~/.gemini/settings.json: \"hooks\" has an unexpected type — Coucou has not touched it."
            ])
        }
        if var hooks = settings["hooks"] as? [String: Any] {
            for key in hooks.keys {
                if let groups = hooks[key] as? [[String: Any]] {
                    let cleaned = removeNbHookEntries(from: groups)
                    if cleaned.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = cleaned }
                }
            }
            if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        }
        return try JSONSerialization.data(withJSONObject: settings,
                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: Antigravity – preview / write

    private var _pendingAgyData: Data?
    private var _pendingAgyFingerprint: String?

    func previewAgyHooks(install: Bool) throws -> String {
        let url = Self.agyHooksURL
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !install && !exists {
            throw NSError(domain: "CoucouNoop", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "No Antigravity hooks to remove."
            ])
        }
        let current = exists ? try Data(contentsOf: url) : Data()
        _pendingAgyFingerprint = sha256Hex(current)
        let newData = install ? try buildAgyHooksData() : try withoutAgyHooks()
        _pendingAgyData = newData
        return String(data: newData, encoding: .utf8) ?? ""
    }

    func writeAgyHooks() throws {
        guard let data = _pendingAgyData, let fp = _pendingAgyFingerprint else { return }
        let url = Self.agyHooksURL
        let current = (try? Data(contentsOf: url)) ?? Data()
        guard sha256Hex(current) == fp else {
            throw NSError(domain: "Coucou", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "~/.gemini/config/hooks.json changed since preview. Refresh and try again."
            ])
        }
        try writeJSONFile(data, to: url, suffix: "hooks.json")
        _pendingAgyData = nil
        _pendingAgyFingerprint = nil
    }

    private func buildAgyHooksData() throws -> Data {
        var root = try Self.strictReadJSONObject(at: Self.agyHooksURL,
                                                 label: "~/.gemini/config/hooks.json")
        let base = hookBase()
        // PreToolUse / PostToolUse: tool-level hooks — use matcher group
        // PreInvocation / PostInvocation / Stop: lifecycle hooks — direct handler, no matcher
        var coucou: [String: Any] = [:]
        for event in ["PreToolUse", "PostToolUse"] {
            let hook: [String: Any] = ["type": "command",
                                       "command": "\(base) --agent antigravity \(event)",
                                       "timeout": 10]
            coucou[event] = [["matcher": "*", "hooks": [hook]]]
        }
        for event in ["PreInvocation", "PostInvocation", "Stop"] {
            let hook: [String: Any] = ["type": "command",
                                       "command": "\(base) --agent antigravity \(event)",
                                       "timeout": 10]
            coucou[event] = [hook]
        }
        root["coucou"] = coucou
        return try JSONSerialization.data(withJSONObject: root,
                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private func withoutAgyHooks() throws -> Data {
        var root = try Self.strictReadJSONObject(at: Self.agyHooksURL,
                                                 label: "~/.gemini/config/hooks.json")
        root.removeValue(forKey: "coucou")
        return try JSONSerialization.data(withJSONObject: root,
                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: Shared helpers

    /// /bin/sh "<hookScriptPath>" — quoted for paths containing spaces (Application Support).
    private func hookBase() -> String {
        let path = Self.hookScriptPath.replacingOccurrences(of: "\"", with: "\\\"")
        return "/bin/sh \"\(path)\""
    }

    /// Reads a JSON object from url.
    /// Absent file → empty dict. Present but invalid → throws with a user-facing message.
    private static func strictReadJSONObject(at url: URL, label: String) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch {
            throw NSError(domain: "Coucou", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "\(label) cannot be read — Coucou has not touched it."
            ])
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw NSError(domain: "Coucou", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "\(label) is not valid JSON — Coucou has not touched it."
            ])
        }
        return obj
    }

    /// Backs up the existing file (throws on failure), creates parent dirs, then atomically writes.
    private func writeJSONFile(_ data: Data, to url: URL, suffix: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyyMMdd-HHmmss"
            let backupURL = url.deletingLastPathComponent()
                .appendingPathComponent("\(suffix).bak-\(fmt.string(from: Date()))")
            do { try fm.copyItem(at: url, to: backupURL) }
            catch {
                throw NSError(domain: "Coucou", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Could not back up \(url.lastPathComponent): \(error.localizedDescription)"
                ])
            }
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Removes entries containing "nb-hook" from a Gemini-format groups array.
    /// Handles both new group format (matcher + hooks[]) and legacy flat format (command at top level).
    /// Returns the cleaned array; empty groups (after inner-hook removal) are dropped.
    private func removeNbHookEntries(from groups: [[String: Any]]) -> [[String: Any]] {
        groups.compactMap { group -> [String: Any]? in
            // Legacy flat entry — command at group level
            if let cmd = group["command"] as? String, cmd.contains("nb-hook") { return nil }
            // Group format — filter inner hooks
            if var innerHooks = group["hooks"] as? [[String: Any]] {
                innerHooks.removeAll { ($0["command"] as? String)?.contains("nb-hook") == true }
                if innerHooks.isEmpty { return nil }
                var updated = group
                updated["hooks"] = innerHooks
                return updated
            }
            return group
        }
    }

    // MARK: - Codex hook installer  (#if !APPSTORE only)

    static var codexHooksURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/hooks.json")
    }

    /// True when ~/.codex/hooks.json already routes Codex events to Coucou's nb-hook.
    static func codexHooksInstalled() -> Bool {
        guard let data = try? Data(contentsOf: codexHooksURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return false }
        for value in hooks.values {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                if let innerHooks = group["hooks"] as? [[String: Any]] {
                    for hook in innerHooks {
                        if let cmd = hook["command"] as? String,
                           cmd.contains("nb-hook"), cmd.contains("--agent codex") { return true }
                    }
                }
            }
        }
        return false
    }

    private var _pendingCodexData: Data?
    private var _pendingCodexFingerprint: String?

    func previewCodexHooks(install: Bool) throws -> String {
        let url = Self.codexHooksURL
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !install && !exists {
            throw NSError(domain: "CoucouNoop", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "No Codex hooks to remove."
            ])
        }
        let current = exists ? try Data(contentsOf: url) : Data()
        _pendingCodexFingerprint = sha256Hex(current)
        let newData = install ? try buildCodexHooksData() : try withoutCodexHooks()
        _pendingCodexData = newData
        return String(data: newData, encoding: .utf8) ?? ""
    }

    func writeCodexHooks() throws {
        guard let data = _pendingCodexData, let fp = _pendingCodexFingerprint else { return }
        let url = Self.codexHooksURL
        let current = (try? Data(contentsOf: url)) ?? Data()
        guard sha256Hex(current) == fp else {
            throw NSError(domain: "Coucou", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "~/.codex/hooks.json changed since preview. Refresh and try again."
            ])
        }
        try writeJSONFile(data, to: url, suffix: "hooks.json")
        _pendingCodexData = nil
        _pendingCodexFingerprint = nil
    }

    private func buildCodexHooksData() throws -> Data {
        var root = try Self.strictReadJSONObject(at: Self.codexHooksURL, label: "~/.codex/hooks.json")
        if let raw = root["hooks"], !(raw is [String: Any]) {
            throw NSError(domain: "Coucou", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "~/.codex/hooks.json: \"hooks\" has an unexpected type — Coucou has not touched it."
            ])
        }
        let base = hookBase()
        // Events, timeouts in seconds (Codex format).
        // PermissionRequest uses 120s + a statusMessage shown in the Codex UI while waiting.
        let events: [(String, Int, String?)] = [
            ("SessionStart",    10,  nil),
            ("UserPromptSubmit", 10, nil),
            ("PreToolUse",      10,  nil),
            ("PermissionRequest", 120, "Waiting for your answer in the notch (Coucou)"),
            ("PostToolUse",     10,  nil),
            ("Stop",            10,  nil),
            ("SubagentStart",   10,  nil),
            ("SubagentStop",    10,  nil),
            ("Interrupt",        3,  nil),
            ("SessionEnd",       3,  nil),
        ]
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, timeout, statusMsg) in events {
            if let raw = hooks[event], !(raw is [[String: Any]]) {
                throw NSError(domain: "Coucou", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "~/.codex/hooks.json: \"hooks\"[\"\(event)\"] has an unexpected type — Coucou has not touched it."
                ])
            }
            var groups = hooks[event] as? [[String: Any]] ?? []
            // Remove existing Coucou entries
            groups = removeNbHookEntries(from: groups)
            var hookEntry: [String: Any] = [
                "type": "command",
                "command": "\(base) --agent codex",
                "timeout": timeout,
            ]
            if let msg = statusMsg { hookEntry["statusMessage"] = msg }
            groups.append(["hooks": [hookEntry]])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: root,
                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private func withoutCodexHooks() throws -> Data {
        var root = try Self.strictReadJSONObject(at: Self.codexHooksURL, label: "~/.codex/hooks.json")
        if let raw = root["hooks"], !(raw is [String: Any]) {
            throw NSError(domain: "Coucou", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "~/.codex/hooks.json: \"hooks\" has an unexpected type — Coucou has not touched it."
            ])
        }
        if var hooks = root["hooks"] as? [String: Any] {
            for key in hooks.keys {
                if let groups = hooks[key] as? [[String: Any]] {
                    let cleaned = removeNbHookEntries(from: groups)
                    if cleaned.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = cleaned }
                }
            }
            if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        }
        return try JSONSerialization.data(withJSONObject: root,
                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: - GitHub Copilot CLI hook installer

    static var copilotHooksURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot/hooks/coucou.json")
    }

    /// True when ~/.copilot/hooks/coucou.json already routes Copilot events to Coucou's nb-hook.
    static func copilotHooksInstalled() -> Bool {
        guard let data = try? Data(contentsOf: copilotHooksURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return false }
        for value in hooks.values {
            guard let entries = value as? [[String: Any]] else { continue }
            for entry in entries {
                if let cmd = entry["bash"] as? String,
                   cmd.contains("nb-hook"), cmd.contains("--agent copilot") { return true }
            }
        }
        return false
    }

    private var _pendingCopilotData: Data?
    private var _pendingCopilotFingerprint: String?

    func previewCopilotHooks(install: Bool) throws -> String {
        let url = Self.copilotHooksURL
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !install && !exists {
            throw NSError(domain: "CoucouNoop", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "No Copilot hooks to remove."
            ])
        }
        let current = exists ? try Data(contentsOf: url) : Data()
        _pendingCopilotFingerprint = sha256Hex(current)
        if install {
            let newData = try buildCopilotHooksData()
            _pendingCopilotData = newData
            return String(data: newData, encoding: .utf8) ?? ""
        } else {
            _pendingCopilotData = nil  // nil = delete signal
            return "(will delete \(url.path))"
        }
    }

    func writeCopilotHooks() throws {
        guard let fp = _pendingCopilotFingerprint else { return }
        let url = Self.copilotHooksURL
        let current = (try? Data(contentsOf: url)) ?? Data()
        guard sha256Hex(current) == fp else {
            throw NSError(domain: "Coucou", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "~/.copilot/hooks/coucou.json changed since preview. Refresh and try again."
            ])
        }
        if let data = _pendingCopilotData {
            try writeJSONFile(data, to: url, suffix: "coucou.json")
        } else {
            // Uninstall: delete the file entirely
            try FileManager.default.removeItem(at: url)
        }
        _pendingCopilotData = nil
        _pendingCopilotFingerprint = nil
    }

    private func buildCopilotHooksData() throws -> Data {
        var root = try Self.strictReadJSONObject(at: Self.copilotHooksURL,
                                                  label: "~/.copilot/hooks/coucou.json")
        if let raw = root["hooks"], !(raw is [String: Any]) {
            throw NSError(domain: "Coucou", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "~/.copilot/hooks/coucou.json: \"hooks\" has an unexpected type — Coucou has not touched it."
            ])
        }
        let base = hookBase()
        // Copilot CLI uses camelCase event names; each entry uses "bash" + "timeoutSec".
        // The event name is passed as a positional arg so the relay can fall back to it.
        // Copilot is fail-closed on permissionRequest — must always output valid JSON.
        let events: [(String, Int)] = [
            ("sessionStart",        10),
            ("userPromptSubmitted", 10),
            ("preToolUse",          10),
            ("permissionRequest",  120),
            ("postToolUse",         10),
            ("agentStop",           10),
            ("sessionEnd",           3),
            ("notification",        10),
        ]
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, timeout) in events {
            if let raw = hooks[event], !(raw is [[String: Any]]) {
                throw NSError(domain: "Coucou", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "~/.copilot/hooks/coucou.json: \"hooks\"[\"\(event)\"] has an unexpected type — Coucou has not touched it."
                ])
            }
            var entries = hooks[event] as? [[String: Any]] ?? []
            entries.removeAll { ($0["bash"] as? String)?.contains("nb-hook") == true }
            entries.append(["type": "command", "bash": "\(base) --agent copilot \(event)", "timeoutSec": timeout])
            hooks[event] = entries
        }
        root["hooks"] = hooks
        root["version"] = 1
        return try JSONSerialization.data(withJSONObject: root,
                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private func withoutCopilotHooks() throws -> Data {
        var root = try Self.strictReadJSONObject(at: Self.copilotHooksURL,
                                                  label: "~/.copilot/hooks/coucou.json")
        if var hooks = root["hooks"] as? [String: Any] {
            for key in hooks.keys {
                if var entries = hooks[key] as? [[String: Any]] {
                    entries.removeAll { ($0["command"] as? String)?.contains("nb-hook") == true }
                    if entries.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = entries }
                }
            }
            if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        }
        return try JSONSerialization.data(withJSONObject: root,
                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: - Muse Code hook installer

    static var museSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/muse/settings.json")
    }

    /// True when ~/.config/muse/settings.json already routes Muse events to Coucou's nb-hook.
    static func museHooksInstalled() -> Bool {
        guard let data = try? Data(contentsOf: museSettingsURL),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any] else { return false }
        for value in hooks.values {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                if let innerHooks = group["hooks"] as? [[String: Any]] {
                    for h in innerHooks {
                        if let cmd = h["command"] as? String,
                           cmd.contains("nb-hook"), cmd.contains("--agent muse") { return true }
                    }
                }
                if let cmd = group["command"] as? String,
                   cmd.contains("nb-hook"), cmd.contains("--agent muse") { return true }
            }
        }
        return false
    }

    private var _pendingMuseData: Data?
    private var _pendingMuseFingerprint: String?

    func previewMuseHooks(install: Bool) throws -> String {
        let url = Self.museSettingsURL
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !install && !exists {
            throw NSError(domain: "CoucouNoop", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "No Muse Code hooks to remove."
            ])
        }
        let current = exists ? try Data(contentsOf: url) : Data()
        _pendingMuseFingerprint = sha256Hex(current)
        let newData = install ? try buildMuseHooksData() : try withoutMuseHooks()
        _pendingMuseData = newData
        return String(data: newData, encoding: .utf8) ?? ""
    }

    func writeMuseHooks() throws {
        guard let data = _pendingMuseData, let fp = _pendingMuseFingerprint else { return }
        let url = Self.museSettingsURL
        let current = (try? Data(contentsOf: url)) ?? Data()
        guard sha256Hex(current) == fp else {
            throw NSError(domain: "Coucou", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "~/.config/muse/settings.json changed since preview. Refresh and try again."
            ])
        }
        try writeJSONFile(data, to: url, suffix: "settings.json")
        _pendingMuseData = nil
        _pendingMuseFingerprint = nil
    }

    private func buildMuseHooksData() throws -> Data {
        var settings = try Self.strictReadJSONObject(at: Self.museSettingsURL,
                                                      label: "~/.config/muse/settings.json")
        if let raw = settings["hooks"], !(raw is [String: Any]) {
            throw NSError(domain: "Coucou", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "~/.config/muse/settings.json: \"hooks\" has an unexpected type — Coucou has not touched it."
            ])
        }
        let base = hookBase()
        // Muse uses PascalCase events. Timeouts in milliseconds (seconds × 1000).
        let events: [(String, Int)] = [
            ("SessionStart",      10),
            ("UserPromptSubmit",   5),
            ("PreToolUse",         5),
            ("PermissionRequest", 120),
            ("PostToolUse",        5),
            ("Stop",               5),
            ("SessionEnd",         3),
        ]
        let isNew = !FileManager.default.fileExists(atPath: Self.museSettingsURL.path)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, timeoutSec) in events {
            if let raw = hooks[event], !(raw is [[String: Any]]) {
                throw NSError(domain: "Coucou", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "~/.config/muse/settings.json: \"hooks\"[\"\(event)\"] has an unexpected type — Coucou has not touched it."
                ])
            }
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups = removeNbHookEntries(from: groups)
            let hookEntry: [String: Any] = [
                "type": "command",
                "command": "\(base) --agent muse \(event)",
                "timeout": timeoutSec * 1000,
            ]
            groups.append(["matcher": "*", "hooks": [hookEntry]])
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        if isNew { settings["schema_version"] = 1 }
        return try JSONSerialization.data(withJSONObject: settings,
                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private func withoutMuseHooks() throws -> Data {
        var settings = try Self.strictReadJSONObject(at: Self.museSettingsURL,
                                                      label: "~/.config/muse/settings.json")
        if let raw = settings["hooks"], !(raw is [String: Any]) {
            throw NSError(domain: "Coucou", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "~/.config/muse/settings.json: \"hooks\" has an unexpected type — Coucou has not touched it."
            ])
        }
        if var hooks = settings["hooks"] as? [String: Any] {
            for key in hooks.keys {
                if let groups = hooks[key] as? [[String: Any]] {
                    let cleaned = removeNbHookEntries(from: groups)
                    if cleaned.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = cleaned }
                }
            }
            if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        }
        return try JSONSerialization.data(withJSONObject: settings,
                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: - OpenCode plugin installer

    private var _pendingOpenCodeContent: String?
    private var _pendingOpenCodeFingerprint: String?

    static var openCodePluginURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/opencode/plugins/coucou.js")
    }

    static func openCodePluginInstalled() -> Bool {
        guard let content = try? String(contentsOf: openCodePluginURL, encoding: .utf8) else { return false }
        return content.contains("nb-hook") && content.contains("opencode")
    }

    private func buildOpenCodePluginContent() -> String {
        let path = Self.hookScriptPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return """
// Coucou hook plugin for OpenCode — generated by Coucou.app
// Forwards every event to the Coucou notch (fire-and-forget, never blocks).
import { spawn } from 'node:child_process';

const HOOK = '\(path)';
const EVENT_MAP = {
  'session.created': 'SessionStart',
  'session.idle': 'Stop',
  'session.error': 'StopFailure',
  'session.deleted': 'SessionEnd',
  'permission.asked': 'PermissionRequest',
};

function forward(hook_event_name, payload) {
  const p = spawn('/bin/sh', [HOOK, '--agent', 'opencode'],
                  { stdio: ['pipe', 'ignore', 'ignore'], detached: true });
  p.on('error', () => {});
  p.stdin.on('error', () => {});
  p.stdin.write(JSON.stringify({ hook_event_name, ...payload }) + '\\n');
  p.stdin.end();
  p.unref();
}

export const CoucouPlugin = async (_ctx) => ({
  event: async ({ event }) => {
    const hook_event_name = EVENT_MAP[event.type];
    if (!hook_event_name) return;
    const props = event.properties || {};
    const payload = {
      session_id: event.sessionID || event.session_id || props.sessionID || props.session_id || '',
      cwd: event.cwd || event.directory || props.cwd || props.directory || '',
    };
    if (typeof props.tool === 'string') payload.tool_name = props.tool;
    if (props.input != null) payload.tool_input = props.input;
    forward(hook_event_name, payload);
  },
  'tool.execute.before': async (input) => {
    forward('PreToolUse', {
      session_id: input.sessionID || input.session_id || '',
      cwd: input.cwd || '',
      tool_name: typeof input.tool === 'string' ? input.tool : '',
      tool_input: input.input ?? null,
    });
  },
  'tool.execute.after': async (input, _output) => {
    forward('PostToolUse', {
      session_id: input.sessionID || input.session_id || '',
      cwd: input.cwd || '',
      tool_name: typeof input.tool === 'string' ? input.tool : '',
    });
  },
});
"""
    }

    func previewOpenCodePlugin(install: Bool) throws -> String {
        let url = Self.openCodePluginURL
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !install {
            guard exists else {
                throw NSError(domain: "CoucouNoop", code: 0, userInfo: [
                    NSLocalizedDescriptionKey: "No OpenCode plugin to remove."
                ])
            }
            let current = (try? Data(contentsOf: url)) ?? Data()
            _pendingOpenCodeFingerprint = sha256Hex(current)
            _pendingOpenCodeContent = nil
            return "(will delete \(url.path))"
        }
        let current = exists ? (try? Data(contentsOf: url)) ?? Data() : Data()
        _pendingOpenCodeFingerprint = sha256Hex(current)
        let content = buildOpenCodePluginContent()
        _pendingOpenCodeContent = content
        return content
    }

    func writeOpenCodePlugin() throws {
        guard let fp = _pendingOpenCodeFingerprint else { return }
        let url = Self.openCodePluginURL
        let current = (try? Data(contentsOf: url)) ?? Data()
        guard sha256Hex(current) == fp else {
            throw NSError(domain: "Coucou", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "~/.config/opencode/plugins/coucou.js changed since preview. Refresh and try again."
            ])
        }
        guard let content = _pendingOpenCodeContent else {
            // Uninstall path: checked by removeOpenCodePlugin
            return
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyyMMdd-HHmmss"
            let backupURL = url.deletingLastPathComponent()
                .appendingPathComponent("coucou.js.bak-\(fmt.string(from: Date()))")
            try fm.copyItem(at: url, to: backupURL)
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        _pendingOpenCodeContent = nil
        _pendingOpenCodeFingerprint = nil
    }

    func removeOpenCodePlugin() throws {
        let url = Self.openCodePluginURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard content.contains("generated by Coucou") else {
            throw NSError(domain: "Coucou", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "~/.config/opencode/plugins/coucou.js was not generated by Coucou — not deleting it."
            ])
        }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Amp plugin installer

    private var _pendingAmpContent: String?
    private var _pendingAmpFingerprint: String?

    static var ampPluginURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/amp/plugins/coucou.ts")
    }

    static func ampPluginInstalled() -> Bool {
        guard let content = try? String(contentsOf: ampPluginURL, encoding: .utf8) else { return false }
        return content.contains("nb-hook") && content.contains("'amp'")
    }

    private func buildAmpPluginContent() -> String {
        let path = Self.hookScriptPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return """
// Coucou hook plugin for Amp — generated by Coucou.app
// Forwards every event to the Coucou notch (display only, never blocks).
import { spawn } from 'node:child_process';

const HOOK = '\(path)';

function forward(event_name: string, fields: Record<string, unknown>): void {
  const payload = JSON.stringify({ hook_event_name: event_name, ...fields });
  const p = spawn('/bin/sh', [HOOK, '--agent', 'amp'],
                  { stdio: ['pipe', 'ignore', 'ignore'], detached: true });
  p.on('error', () => {});
  (p.stdin as import('node:stream').Writable).on('error', () => {});
  (p.stdin as import('node:stream').Writable).write(payload + '\\n');
  (p.stdin as import('node:stream').Writable).end();
  p.unref();
}

export default function (amp: any): void {
  amp.on('session.start', (e: any) => { forward('SessionStart',     { session_id: e.thread?.id ?? '' }); });
  amp.on('agent.start',   (e: any) => { forward('UserPromptSubmit', { session_id: e.thread?.id ?? '' }); });
  amp.on('tool.call',     (e: any) => { try { forward('PreToolUse', { session_id: e.thread?.id ?? '', tool_name: typeof e.tool === 'string' ? e.tool : '' }); } finally { return { action: 'allow' }; } });
  amp.on('tool.result',   (e: any) => { forward('PostToolUse',      { session_id: e.thread?.id ?? '' }); });
  amp.on('agent.end',     (e: any) => { forward('Stop',             { session_id: e.thread?.id ?? '' }); });
}
"""
    }

    func previewAmpPlugin(install: Bool) throws -> String {
        let url = Self.ampPluginURL
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !install {
            guard exists else {
                throw NSError(domain: "CoucouNoop", code: 0, userInfo: [
                    NSLocalizedDescriptionKey: "No Amp plugin to remove."
                ])
            }
            let current = (try? Data(contentsOf: url)) ?? Data()
            _pendingAmpFingerprint = sha256Hex(current)
            _pendingAmpContent = nil
            return "(will delete \(url.path))"
        }
        let current = exists ? (try? Data(contentsOf: url)) ?? Data() : Data()
        _pendingAmpFingerprint = sha256Hex(current)
        let content = buildAmpPluginContent()
        _pendingAmpContent = content
        return content
    }

    func writeAmpPlugin() throws {
        guard let fp = _pendingAmpFingerprint else { return }
        let url = Self.ampPluginURL
        let current = (try? Data(contentsOf: url)) ?? Data()
        guard sha256Hex(current) == fp else {
            throw NSError(domain: "Coucou", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "~/.config/amp/plugins/coucou.ts changed since preview. Refresh and try again."
            ])
        }
        guard let content = _pendingAmpContent else {
            // Uninstall path: checked by removeAmpPlugin
            return
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyyMMdd-HHmmss"
            let backupURL = url.deletingLastPathComponent()
                .appendingPathComponent("coucou.ts.bak-\(fmt.string(from: Date()))")
            try fm.copyItem(at: url, to: backupURL)
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        _pendingAmpContent = nil
        _pendingAmpFingerprint = nil
    }

    func removeAmpPlugin() throws {
        let url = Self.ampPluginURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard content.contains("generated by Coucou") else {
            throw NSError(domain: "Coucou", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "~/.config/amp/plugins/coucou.ts was not generated by Coucou — not deleting it."
            ])
        }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Hermes plugin installer

    private var _pendingHermesPluginContent: String?
    private var _pendingHermesPluginFingerprint: String?
    private var _pendingHermesConfigContent: String?
    private var _pendingHermesConfigFingerprint: String?

    static var hermesPluginDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/plugins/coucou")
    }
    static var hermesInitPyURL: URL { hermesPluginDir.appendingPathComponent("__init__.py") }
    static var hermesPluginYamlURL: URL { hermesPluginDir.appendingPathComponent("plugin.yaml") }
    static var hermesConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/config.yaml")
    }

    static func hermesPluginInstalled() -> Bool {
        guard let content = try? String(contentsOf: hermesInitPyURL, encoding: .utf8) else { return false }
        return content.contains("nb-hook") && content.contains("hermes")
    }

    /// Returns true if the installed Hermes version exposes register_approval_transport.
    /// Runs a quick python3 import check; returns false on any error or if hermes is not installed.
    /// Finds the `hermes` executable in PATH and common install locations.
    private static func hermesExecutablePath() -> String? {
        // Try PATH via `which` first
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["hermes"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError  = Pipe()
        if (try? which.run()) != nil {
            which.waitUntilExit()
            if which.terminationStatus == 0 {
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !out.isEmpty && FileManager.default.isExecutableFile(atPath: out) { return out }
            }
        }
        // Explicit common locations
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for candidate in [
            "\(home)/.local/bin/hermes",
            "\(home)/.hermes/bin/hermes",
            "/usr/local/bin/hermes",
            "/opt/homebrew/bin/hermes",
        ] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Reads the shebang of `executablePath` and returns the interpreter path.
    /// Handles `#!/usr/bin/env python3` by resolving via `which`.
    private static func interpreterFromShebang(_ executablePath: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: executablePath) else { return nil }
        let data = fh.readData(ofLength: 512)
        try? fh.close()
        guard let text = String(data: data, encoding: .utf8),
              text.hasPrefix("#!") else { return nil }
        let line = String(text.prefix(while: { $0 != "\n" }).dropFirst(2))
            .trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("/usr/bin/env ") {
            let name = String(line.dropFirst("/usr/bin/env ".count))
                .trimmingCharacters(in: .whitespaces)
            let task = Process(); let pipe = Pipe()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            task.arguments = [name]; task.standardOutput = pipe; task.standardError = Pipe()
            if (try? task.run()) != nil {
                task.waitUntilExit()
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return out.isEmpty ? nil : out
            }
            return nil
        }
        return line.isEmpty ? nil : line
    }

    /// Returns true if the installed Hermes version exposes register_approval_transport.
    /// Finds the hermes binary, reads its shebang to get the right interpreter (never uses
    /// system python3), and runs an import check with a 3-second timeout.
    /// Returns false if hermes/interpreter not found, or import fails.
    #if !APPSTORE
    static func hermesSupportsApprovalTransport() -> Bool {
        guard let hermesPath = hermesExecutablePath(),
              let pythonPath = interpreterFromShebang(hermesPath),
              FileManager.default.isExecutableFile(atPath: pythonPath) else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: pythonPath)
        task.arguments     = ["-c", "from hermes_cli.approval_transport import ApprovalRequest"]
        task.standardOutput = Pipe(); task.standardError = Pipe()
        do { try task.run() } catch { return false }
        // Wait up to 3 seconds
        let group = DispatchGroup(); group.enter()
        var exited = false
        DispatchQueue.global(qos: .background).async { task.waitUntilExit(); exited = true; group.leave() }
        if group.wait(timeout: .now() + 3) == .timedOut { task.terminate(); return false }
        return task.terminationStatus == 0
    }
    #endif

    private func buildHermesInitPy() -> String {
        let path = Self.hookScriptPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return """
# Coucou hook plugin for Hermes Agent — generated by Coucou.app
# Session/tool events → Coucou notch (fire-and-forget, never blocks).
# Approval transport: uses register_approval_transport when available (future Hermes),
# falls back to pre_approval_request observer-only hook (hermes 0.15.x).
import json, subprocess, threading
from pathlib import Path

HOOK = Path('\(path)')
_lock = threading.Lock()
# Maps session_id → metadata dict. Keeps correct session when multiple
# sessions run concurrently (gateway mode). _current_session_id is kept as
# a last-seen fallback for hooks that don't supply a session_id.
_sessions: dict = {}
_current_session_id = ''


def _fire(fields: dict) -> None:
    \"\"\"Non-blocking: spawn nb-hook and return immediately. Reaps child to avoid zombies.\"\"\"
    def _run() -> None:
        try:
            p = subprocess.Popen(
                [str(HOOK), '--agent', 'hermes'],
                stdin=subprocess.PIPE,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,   # detach from process group
            )
            p.stdin.write(json.dumps(fields).encode() + b'\\n')
            p.stdin.close()
            p.wait(timeout=5)             # reap; 5s >> the 0.3s socket timeout
        except Exception:
            pass
    threading.Thread(target=_run, daemon=True).start()


def register(ctx) -> None:
    def on_session_start(**kwargs) -> None:
        global _current_session_id
        sid = kwargs.get('session_id', '')
        meta = {
            'model': kwargs.get('model', ''),
            'platform': kwargs.get('platform', 'cli') or 'cli',
        }
        with _lock:
            _sessions[sid] = meta
            _current_session_id = sid
        _fire({'hook_event_name': 'SessionStart', 'session_id': sid, 'platform': meta['platform']})

    def on_session_end(**kwargs) -> None:
        sid = kwargs.get('session_id', '')
        with _lock:
            _sessions.pop(sid, None)
        # Stop is sent by post_llm_call (which has the last assistant message).
        # Only send StopFailure here when the session was interrupted abnormally.
        if kwargs.get('interrupted'):
            _fire({'hook_event_name': 'StopFailure', 'session_id': sid})

    def post_llm_call(**kwargs) -> None:
        sid = kwargs.get('session_id', '') or _current_session_id
        response = kwargs.get('assistant_response', '')
        _fire({
            'hook_event_name': 'Stop',
            'session_id': sid,
            'last_assistant_message': response,
        })

    def pre_tool_call(**kwargs) -> None:
        sid = kwargs.get('session_id', '') or _current_session_id
        _fire({
            'hook_event_name': 'PreToolUse',
            'session_id': sid,
            'tool_name': kwargs.get('tool_name', ''),
            'tool_input': kwargs.get('args') or {},
        })

    def post_tool_call(**kwargs) -> None:
        sid = kwargs.get('session_id', '') or _current_session_id
        _fire({
            'hook_event_name': 'PostToolUse',
            'session_id': sid,
            'tool_name': kwargs.get('tool_name', ''),
        })

    ctx.register_hook('on_session_start', on_session_start)
    ctx.register_hook('on_session_end',   on_session_end)
    ctx.register_hook('post_llm_call',    post_llm_call)
    ctx.register_hook('pre_tool_call',    pre_tool_call)
    ctx.register_hook('post_tool_call',   post_tool_call)

    if hasattr(ctx, 'register_approval_transport'):
        # Hermes version supports transport API — Coucou shows a real Allow/Deny card
        # and returns the user's choice to Hermes.
        def _present(request) -> object:
            sid = (getattr(request, 'session_id', None)
                   or getattr(request, 'session_key', None)
                   or _current_session_id)
            cmd     = getattr(request, 'command', '')
            desc    = getattr(request, 'description', '')
            timeout = getattr(request, 'timeout_seconds',
                              getattr(request, 'timeout', 30.0))
            allowed = list(getattr(request, 'allowed_choices', ('once', 'deny')))

            payload = json.dumps({
                'hook_event_name': 'PermissionRequest',
                'session_id': sid,
                'coucou_agent': 'hermes',
                'coucou_has_transport': True,
                'tool_name': cmd,
                'tool_input': {'command': cmd, 'description': desc},
            }).encode()
            try:
                result = subprocess.run(
                    [str(HOOK), '--agent', 'hermes'],
                    input=payload,
                    capture_output=True,
                    timeout=max(1.0, float(timeout) - 2.0),
                )
                data   = json.loads(result.stdout)
                choice = data['choice']
                if choice not in allowed:
                    raise ValueError(f'invalid choice: {choice!r}')
                return request.respond(choice)
            except Exception:
                # Fall back to Hermes' native prompt on any error.
                return request.respond('deny')

        ctx.register_approval_transport('coucou', _present)
    else:
        # Observer-only hook (hermes 0.15.x): Hermes still controls the decision.
        # Fire a PreToolUse-style step so the notch shows "⏳ Approval pending in Hermes"
        # in the step list without displaying a fake Allow/Deny card.
        def pre_approval_request(**kwargs) -> None:
            sid = kwargs.get('session_key', '') or _current_session_id
            _fire({
                'hook_event_name': 'PreToolUse',
                'session_id': sid,
                'tool_name': '⏳ Approval pending in Hermes',
                'tool_input': {
                    'command': kwargs.get('command', ''),
                    'description': kwargs.get('description', ''),
                },
            })

        ctx.register_hook('pre_approval_request', pre_approval_request)
"""
    }

    private static let hermesPluginYaml = """
name: coucou
version: "1.0"
description: Coucou notch integration — generated by Coucou.app
"""

    /// Merges Coucou keys into a Hermes config.yaml string without touching other settings.
    ///
    /// Returns the merged YAML string, or nil if the file uses an unsupported structure
    /// (flow maps `{…}`, YAML anchors `&`, multi-document `---`) that the line-level
    /// merger cannot safely handle. Callers should surface an error with the lines
    /// the user needs to add manually.
    ///
    /// Plugin enablement (plugins.enabled) is handled by the `hermes plugins enable/disable`
    /// CLI after the plugin files are written; this function only manages security.approval.
    static func mergedHermesConfig(_ base: String, enableApprovals: Bool) -> String? {
        // Reject structures the simple merger cannot handle safely.
        // Flow maps, anchors, and multi-document markers require a full YAML parser.
        let unsafePatterns = ["{", " &", "\n---"]
        for p in unsafePatterns where base.contains(p) {
            return nil
        }

        var lines = base.components(separatedBy: "\n")

        // Detect file indentation: look for the first indented line and count spaces.
        let indent: Int = {
            for line in lines {
                let leading = line.prefix(while: { $0 == " " }).count
                if leading > 0 && leading <= 8 { return leading }
            }
            return 2  // default
        }()
        let ind  = String(repeating: " ", count: indent)         // e.g. "  " (2) or "    " (4)
        let ind2 = String(repeating: " ", count: indent * 2)     // one extra level

        // Returns the index of the first top-level section header line matching `key`.
        // Top-level = no leading spaces, ends with `:` (optionally with trailing space/comment).
        func topLevelIndex(key: String) -> Int? {
            lines.firstIndex { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix(" ") && !line.hasPrefix("\t") else { return false }
                return t == "\(key):" || t.hasPrefix("\(key):")
            }
        }

        // Returns the range of lines that belong to a top-level section (from its header to
        // just before the next top-level section, or the end of the array).
        func sectionRange(from sectionIdx: Int) -> Range<Int> {
            var end = sectionIdx + 1
            while end < lines.count {
                let l = lines[end]
                // A new top-level key: not blank, not a comment, no leading whitespace
                if !l.isEmpty && !l.hasPrefix("#") && !l.hasPrefix(" ") && !l.hasPrefix("\t") {
                    break
                }
                end += 1
            }
            return sectionIdx ..< end
        }

        // --- security.approval ---
        let transportLine = "\(ind2)transport: coucou"
        let fallbackLine  = "\(ind2)transport_fallback: builtin"

        func ensureApprovalTransport() {
            if let secIdx = topLevelIndex(key: "security") {
                let secRange = sectionRange(from: secIdx)
                // Look for approval: within the security section (must be indented)
                if let approvalIdx = (secRange.lowerBound + 1 ..< secRange.upperBound)
                    .first(where: { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("approval:") }) {
                    // approval: block exists — update or add transport keys within it
                    let approvalRange = sectionRange(from: approvalIdx)
                    var hasTransport = false
                    var hasFallback  = false
                    for i in (approvalRange.lowerBound + 1 ..< approvalRange.upperBound) {
                        let t = lines[i].trimmingCharacters(in: .whitespaces)
                        if t.hasPrefix("transport:") && !t.hasPrefix("transport_fallback") {
                            lines[i] = transportLine; hasTransport = true
                        } else if t.hasPrefix("transport_fallback:") {
                            lines[i] = fallbackLine; hasFallback = true
                        }
                    }
                    let insertAt = approvalRange.lowerBound + 1
                    if !hasFallback  { lines.insert(fallbackLine,  at: insertAt) }
                    if !hasTransport { lines.insert(transportLine, at: insertAt) }
                } else {
                    // No approval: key — insert right after security:
                    let insertAt = secIdx + 1
                    lines.insert("\(ind)approval:", at: insertAt)
                    lines.insert(transportLine,     at: insertAt + 1)
                    lines.insert(fallbackLine,      at: insertAt + 2)
                }
            } else {
                // No security: section — append
                if lines.last != "" { lines.append("") }
                lines.append("security:")
                lines.append("\(ind)approval:")
                lines.append(transportLine)
                lines.append(fallbackLine)
            }
        }

        func removeApprovalTransport() {
            // Only remove exact Coucou-written transport keys; don't touch unrelated keys.
            lines.removeAll { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return t == "transport: coucou" || t == "transport_fallback: builtin"
            }
        }

        // --- plugins.enabled ---
        // Note: actual plugin enable/disable is done via `hermes plugins enable/disable coucou`
        // CLI after writing/removing the plugin files. This block ensures the preview
        // shows the complete intended state of config.yaml.
        func ensureCoucouPlugin() {
            // "Already present" = coucou in the plugins.enabled list specifically.
            // Check by finding plugins: section first, then enabled: sub-key within it.
            if let pluginsIdx = topLevelIndex(key: "plugins") {
                let pluginsRange = sectionRange(from: pluginsIdx)
                // Find enabled: within the plugins section
                if let enabledIdx = (pluginsRange.lowerBound + 1 ..< pluginsRange.upperBound)
                    .first(where: { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("enabled:") }) {
                    let enabledLine = lines[enabledIdx]
                    let trimmed = enabledLine.trimmingCharacters(in: .whitespaces)
                    if trimmed.contains("[") && trimmed.contains("]") {
                        // Inline list: enabled: [x, y]  or  enabled: []
                        if trimmed.contains("coucou") { return }   // already present
                        if trimmed == "enabled: []" || trimmed == "enabled:[]" {
                            // Empty inline list → expand to block entry
                            let prefix = enabledLine.prefix(while: { $0 == " " })
                            lines[enabledIdx] = "\(prefix)enabled:"
                            lines.insert("\(prefix)\(ind)- coucou", at: enabledIdx + 1)
                        } else {
                            lines[enabledIdx] = enabledLine.replacingOccurrences(of: "]", with: ", coucou]")
                        }
                    } else {
                        // Block list — check if coucou is already a child of this enabled:
                        let enabledRange = sectionRange(from: enabledIdx)
                        let alreadyPresent = (enabledRange.lowerBound + 1 ..< enabledRange.upperBound)
                            .contains { lines[$0].trimmingCharacters(in: .whitespaces) == "- coucou" }
                        if alreadyPresent { return }
                        // Insert after enabled:
                        let prefix = enabledLine.prefix(while: { $0 == " " })
                        lines.insert("\(prefix)\(ind)- coucou", at: enabledIdx + 1)
                    }
                } else {
                    // No enabled: key under plugins: — insert after plugins:
                    lines.insert("\(ind)enabled:", at: pluginsIdx + 1)
                    lines.insert("\(ind)\(ind)- coucou", at: pluginsIdx + 2)
                }
            } else {
                // No plugins: section — append
                if lines.last != "" { lines.append("") }
                lines.append("plugins:")
                lines.append("\(ind)enabled:")
                lines.append("\(ind)\(ind)- coucou")
            }
        }

        func removeCoucouPlugin() {
            // Remove the `- coucou` entry from plugins.enabled only.
            // If that leaves enabled: with no entries, leave the key in place (don't remove it).
            guard let pluginsIdx = topLevelIndex(key: "plugins") else { return }
            let pluginsRange = sectionRange(from: pluginsIdx)
            guard let enabledIdx = (pluginsRange.lowerBound + 1 ..< pluginsRange.upperBound)
                .first(where: { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("enabled:") })
            else { return }
            let enabledLine = lines[enabledIdx]
            let trimmed = enabledLine.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("[") && trimmed.contains("]") {
                // Inline list: remove coucou from it
                let cleaned = trimmed
                    .replacingOccurrences(of: ", coucou", with: "")
                    .replacingOccurrences(of: "coucou, ", with: "")
                    .replacingOccurrences(of: "coucou",   with: "")
                let prefix = enabledLine.prefix(while: { $0 == " " })
                lines[enabledIdx] = "\(prefix)\(cleaned)"
            } else {
                // Block list: remove the `- coucou` entry
                let enabledRange = sectionRange(from: enabledIdx)
                // Collect indices to remove first, then remove in reverse to preserve indices.
                let toRemove = (enabledRange.lowerBound + 1 ..< enabledRange.upperBound)
                    .filter { lines[$0].trimmingCharacters(in: .whitespaces) == "- coucou" }
                for i in toRemove.reversed() { lines.remove(at: i) }
            }
        }

        ensureCoucouPlugin()
        if enableApprovals { ensureApprovalTransport() } else { removeApprovalTransport() }
        return lines.joined(separator: "\n")
    }

    func previewHermesPlugin(install: Bool) throws -> String {
        if !install {
            guard FileManager.default.fileExists(atPath: Self.hermesInitPyURL.path) else {
                throw NSError(domain: "CoucouNoop", code: 0, userInfo: [
                    NSLocalizedDescriptionKey: "No Hermes plugin to remove."
                ])
            }
            let current = (try? Data(contentsOf: Self.hermesInitPyURL)) ?? Data()
            _pendingHermesPluginFingerprint = sha256Hex(current)
            _pendingHermesPluginContent = nil
            return "(will delete \(Self.hermesInitPyURL.path))"
        }
        let current = (try? Data(contentsOf: Self.hermesInitPyURL)) ?? Data()
        _pendingHermesPluginFingerprint = sha256Hex(current)
        let content = buildHermesInitPy()
        _pendingHermesPluginContent = content
        return content
    }

    func writeHermesPlugin() throws {
        guard let fp = _pendingHermesPluginFingerprint else { return }
        let url = Self.hermesInitPyURL
        let current = (try? Data(contentsOf: url)) ?? Data()
        guard sha256Hex(current) == fp else {
            throw NSError(domain: "Coucou", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "~/.hermes/plugins/coucou/__init__.py changed since preview. Refresh and try again."
            ])
        }
        let fm = FileManager.default
        if let content = _pendingHermesPluginContent {
            try fm.createDirectory(at: Self.hermesPluginDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: url.path) {
                let fmt = DateFormatter()
                fmt.locale = Locale(identifier: "en_US_POSIX")
                fmt.dateFormat = "yyyyMMdd-HHmmss"
                let bak = url.deletingLastPathComponent()
                    .appendingPathComponent("__init__.py.bak-\(fmt.string(from: Date()))")
                try fm.copyItem(at: url, to: bak)
            }
            try content.write(to: url, atomically: true, encoding: .utf8)
            try Self.hermesPluginYaml.write(to: Self.hermesPluginYamlURL, atomically: true, encoding: .utf8)
            // Register the plugin with the Hermes CLI so it appears in plugins.enabled.
            // Best-effort — silently ignored if hermes is not on PATH.
            try? Self.runHermesCLI(["plugins", "enable", "coucou"])
        }
        _pendingHermesPluginContent = nil
        _pendingHermesPluginFingerprint = nil
    }

    func removeHermesPlugin() throws {
        let url = Self.hermesInitPyURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard content.contains("generated by Coucou") else {
            throw NSError(domain: "Coucou", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "~/.hermes/plugins/coucou/__init__.py was not generated by Coucou — not deleting it."
            ])
        }
        // Remove from hermes plugins.enabled first, then delete the files.
        // Best-effort — silently ignored if hermes is not on PATH.
        try? Self.runHermesCLI(["plugins", "disable", "coucou"])
        try FileManager.default.removeItem(at: Self.hermesPluginDir)
    }

    /// Invoke the Hermes CLI with the given arguments.
    /// Searches standard PATH locations for the `hermes` binary.
    @discardableResult
    private static func runHermesCLI(_ args: [String]) throws -> String {
        let hermesPaths = [
            "/opt/homebrew/bin/hermes",
            "/usr/local/bin/hermes",
            "/usr/bin/hermes",
            (ProcessInfo.processInfo.environment["HOME"] ?? "") + "/.local/bin/hermes",
        ]
        guard let hermesBin = hermesPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw NSError(domain: "CoucouNoop", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "hermes CLI not found."
            ])
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: hermesBin)
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError  = Pipe()   // discard stderr
        try proc.run()
        proc.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    func previewHermesConfig(enableApprovals: Bool, supportsTransport: Bool) throws -> String {
        let base = (try? String(contentsOf: Self.hermesConfigURL, encoding: .utf8)) ?? ""
        let current = (try? Data(contentsOf: Self.hermesConfigURL)) ?? Data()
        _pendingHermesConfigFingerprint = sha256Hex(current)
        let effectiveApprovals = enableApprovals && supportsTransport
        guard let merged = Self.mergedHermesConfig(base, enableApprovals: effectiveApprovals) else {
            _pendingHermesConfigContent = nil
            throw NSError(domain: "Coucou", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "~/.hermes/config.yaml uses an unsupported structure (flow maps, YAML anchors, or multi-document). Edit it manually and add:\n  security:\n    approval:\n      transport: coucou\n      transport_fallback: builtin"
            ])
        }
        _pendingHermesConfigContent = merged
        return merged
    }

    func writeHermesConfig() throws {
        guard let fp = _pendingHermesConfigFingerprint,
              let content = _pendingHermesConfigContent else { return }
        let url = Self.hermesConfigURL
        let current = (try? Data(contentsOf: url)) ?? Data()
        guard sha256Hex(current) == fp else {
            throw NSError(domain: "Coucou", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "~/.hermes/config.yaml changed since preview. Refresh and try again."
            ])
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyyMMdd-HHmmss"
            let bak = url.deletingLastPathComponent()
                .appendingPathComponent("config.yaml.bak-\(fmt.string(from: Date()))")
            try fm.copyItem(at: url, to: bak)
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        _pendingHermesConfigContent = nil
        _pendingHermesConfigFingerprint = nil
    }

    // MARK: SHA-256 fingerprint

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    #endif
}

// MARK: - Notification names for hook server → controller communication

extension Notification.Name {
    static let hookExpand = Notification.Name("notchBuddy.hookExpand")
}

// MARK: - nb-hook shell wrapper (same for both GitHub and App Store)
// Invoked by Claude Code via /bin/sh or directly via shebang.
// Always exits 0 — never blocks Claude Code.
// Checks xcode-select before running python3 to avoid triggering the
// "install developer tools" dialog on machines without Xcode CLI tools.

private let nbHookShellWrapper = """
#!/bin/sh
# Coucou hook relay — always exits 0, never blocks Claude Code
HOOK_DIR="$(dirname "$0")"
out=""
if xcode-select -p >/dev/null 2>&1; then
    out=$(/usr/bin/python3 "$HOOK_DIR/nb-hook.py" "$@" 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
        out=""
    fi
fi
if [ -n "$out" ]; then
    printf '%s\\n' "$out"
else
    # Copilot is fail-closed — must always output valid JSON even when python3 is absent or crashes.
    _cop=0; _perm=0
    for _a in "$@"; do
        case "$_a" in
            copilot) _cop=1 ;;
            permissionRequest|PermissionRequest) _perm=1 ;;
        esac
    done
    if [ "$_cop" -eq 1 ]; then
        if [ "$_perm" -eq 1 ]; then
            printf '{"permissionDecision":"ask"}\\n'
        else
            printf '{}\\n'
        fi
    fi
fi
exit 0
"""

// MARK: - nb-hook Python relay (GitHub / non-sandboxed version)

private let nbHookPythonGitHub = """
#!/usr/bin/env python3
# nb-hook.py — Coucou hook relay for Claude Code and third-party agents (GitHub version)
# Reads JSON from stdin, forwards to Coucou via Unix socket, translates response.
import sys, json, os, socket

def normalize_event(name):
    mapping = {
        'BeforeTool': 'PreToolUse', 'BeforeToolSelection': 'PreToolUse',
        'AfterTool': 'PostToolUse', 'AfterModel': 'PostToolUse',
        'BeforeAgent': 'UserPromptSubmit', 'AfterAgent': 'Stop',
        'startup': 'SessionStart', 'exit': 'SessionEnd',
        'PreInvocation': 'UserPromptSubmit', 'PostInvocation': 'PostToolUse',
        'pre_tool_use': 'PreToolUse', 'post_tool_use': 'PostToolUse',
        'user_prompt_submit': 'UserPromptSubmit', 'session_start': 'SessionStart',
        'session_end': 'SessionEnd', 'stop': 'Stop',
        'sessionStart': 'SessionStart', 'userPromptSubmitted': 'UserPromptSubmit',
        'agentStop': 'Stop', 'notification': 'Notification',
        'preToolUse': 'PreToolUse', 'postToolUse': 'PostToolUse',
        'permissionRequest': 'PermissionRequest', 'sessionEnd': 'SessionEnd',
    }
    return mapping.get(name, name)

def normalize_tool_fields(payload):
    if 'tool_name' not in payload:
        # Copilot sends toolName directly; other agents nest in toolCall
        if payload.get('toolName'):
            payload['tool_name'] = payload['toolName']
        else:
            tool = payload.get('toolCall')
            if not isinstance(tool, dict):
                tool = {}
            name = tool.get('name') or payload.get('tool', '')
            if name:
                payload['tool_name'] = name
    if 'tool_input' not in payload:
        # Copilot sends toolArgs directly
        tool_args = payload.get('toolArgs')
        if isinstance(tool_args, dict):
            payload['tool_input'] = tool_args
        else:
            tool = payload.get('toolCall') or {}
            if isinstance(tool.get('args'), dict):
                flat = dict(tool['args'])
                for src, dst in [('CommandLine', 'command'), ('FilePath', 'file_path'),
                                 ('Path', 'path'), ('Url', 'url'), ('Query', 'query'), ('Pattern', 'pattern')]:
                    if src in flat:
                        flat[dst] = flat[src]
                payload['tool_input'] = flat
    if 'session_id' not in payload:
        for k in ['conversationId', 'conversation_id', 'sessionId', 'GEMINI_SESSION_ID']:
            if payload.get(k):
                payload['session_id'] = payload[k]
                break
        if 'session_id' not in payload:
            sid = os.environ.get('GEMINI_SESSION_ID', '')
            if sid:
                payload['session_id'] = sid
    # Copilot sends workdir for the current working directory
    if not payload.get('cwd') and payload.get('workdir'):
        payload['cwd'] = payload['workdir']

def main():
    raw = b''
    payload = {}
    try:
        raw = sys.stdin.buffer.read()
        if not raw:
            if '--statusline' not in sys.argv[1:]:
                return
        else:
            payload = json.loads(raw)
    except Exception:
        if '--statusline' not in sys.argv[1:]:
            return

    socket_path = os.path.expanduser(
        '~/Library/Application Support/NotchBuddy/nb.sock'
    )

    # --statusline mode: relay rate_limits to Coucou, then delegate to saved previous
    if '--statusline' in sys.argv[1:]:
        relay = {
            'coucou_kind': 'statusline',
            'session_id': payload.get('session_id', ''),
            'rate_limits': payload.get('rate_limits', {}),
        }
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(0.3)
            s.connect(socket_path)
            s.sendall((json.dumps(relay) + '\\n').encode())
            s.close()
        except Exception:
            pass
        prev_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'statusline-previous.json')
        if os.path.exists(prev_file):
            try:
                import subprocess
                with open(prev_file) as f:
                    prev = json.load(f)
                cmd = prev.get('command', '')
                if cmd:
                    result = subprocess.run(['/bin/sh', '-c', cmd], input=raw,
                                             capture_output=True, timeout=10)
                    if result.stdout:
                        sys.stdout.buffer.write(result.stdout)
                        sys.stdout.buffer.flush()
            except Exception:
                pass
        return

    # --ask mode: dedicated hook for AskUserQuestion via PreToolUse (Claude Code 2.1.85+)
    if '--ask' in sys.argv[1:]:
        tool = payload.get('tool_name', '')
        if tool != 'AskUserQuestion':
            return  # Not an AskUserQuestion invocation — exit cleanly (no output)
        payload['coucou_kind'] = 'ask_user_question'
        env = os.environ
        payload.setdefault('term_program', env.get('TERM_PROGRAM', ''))
        payload.setdefault('iterm_session_id', env.get('ITERM_SESSION_ID', ''))
        payload.setdefault('term_session_id', env.get('TERM_SESSION_ID', ''))
        payload.setdefault('bundle_id', env.get('__CFBundleIdentifier', ''))
        if 'cwd' not in payload or not payload['cwd']:
            paths = payload.get('workspacePaths') or payload.get('workspace_roots', [])
            if isinstance(paths, list) and paths:
                payload['cwd'] = paths[0]
            else:
                payload['cwd'] = os.getcwd()
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(125)
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
                if decision == 'answer':
                    answers = resp_obj.get('answers', {})
                    questions = payload.get('tool_input', {}).get('questions', [])
                    out = {'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': 'allow', 'updatedInput': {'questions': questions, 'answers': answers}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                # 'ask' or unknown: fall through → no output → Claude Code asks in terminal
        except Exception:
            pass
        return

    # Parse --agent <name> and optional positional event from argv.
    # --agent tags the payload with coucou_agent so the app routes to the right pill.
    # The positional arg is a fallback event name for agents that do not set hook_event_name.
    args = sys.argv[1:]
    agent = ''
    arg_event = ''
    i = 0
    while i < len(args):
        if args[i] == '--agent' and i + 1 < len(args):
            agent = args[i + 1]
            i += 2
        else:
            if not arg_event:
                arg_event = args[i]
            i += 1
    if agent:
        payload.setdefault('coucou_agent', agent)
    # Claude Code sessions from the Claude desktop app (Code tab) report this entrypoint;
    # route them to the Claude Desktop pill instead of dropping them (no VS Code terminal).
    if not payload.get('coucou_agent') and os.environ.get('CLAUDE_CODE_ENTRYPOINT') == 'claude-desktop':
        payload['coucou_agent'] = 'claude-desktop'

    # Enrich with terminal context
    env = os.environ
    payload.setdefault('term_program', env.get('TERM_PROGRAM', ''))
    payload.setdefault('iterm_session_id', env.get('ITERM_SESSION_ID', ''))
    payload.setdefault('term_session_id', env.get('TERM_SESSION_ID', ''))
    payload.setdefault('bundle_id', env.get('__CFBundleIdentifier', ''))
    if 'cwd' not in payload or not payload['cwd']:
        paths = payload.get('workspacePaths') or payload.get('workspace_roots', [])
        if isinstance(paths, list) and paths:
            payload['cwd'] = paths[0]
        else:
            payload['cwd'] = os.getcwd()

    # Normalize event name and tool fields (Gemini CLI / Antigravity → canonical names)
    try:
        raw_event = payload.get('hook_event_name', '') or arg_event
        if raw_event:
            payload['hook_event_name'] = normalize_event(raw_event)
        normalize_tool_fields(payload)
    except Exception:
        pass

    event = payload.get('hook_event_name', '')
    # socket_path is already defined above

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
                if agent == 'hermes':
                    hermes_choice = 'once' if decision == 'allow' else decision
                    if hermes_choice in ('once', 'always', 'deny'):
                        sys.stdout.write(json.dumps({'choice': hermes_choice}) + '\\n')
                        sys.stdout.flush()
                    sys.exit(0)
                if decision in ('allow', 'always'):
                    # Copilot/Muse use {"permissionDecision":"allow"} directly
                    if agent in ('copilot', 'muse'):
                        out = {'permissionDecision': 'allow'}
                    elif decision == 'always' and agent != 'codex':
                        # Let Claude Code persist the rule via updatedPermissions
                        suggestions = payload.get('permission_suggestions', [])
                        out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow', 'updatedPermissions': suggestions}}}
                    else:
                        # Claude Code / Codex plain allow
                        out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'deny':
                    if agent in ('copilot', 'muse'):
                        out = {'permissionDecision': 'deny'}
                    else:
                        out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'deny', 'message': 'Denied from Coucou'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'answer':
                    # AskUserQuestion answered from the notch
                    answers = resp_obj.get('answers', {})
                    questions = payload.get('tool_input', {}).get('questions', [])
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow', 'updatedInput': {'questions': questions, 'answers': answers}}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                # 'ask' or unknown: fall through → no output → agent re-asks
        except Exception:
            pass
        # App unreachable, timed out, or no explicit decision — print nothing
        # Copilot is fail-closed: must always output valid JSON so it re-asks rather than deny
        # Hermes: no output → json.loads raises in plugin → transport_fallback: builtin activates
        if agent == 'copilot':
            sys.stdout.write('{"permissionDecision":"ask"}\\n')
            sys.stdout.flush()
        sys.exit(0)

    # All other events: fire-and-forget (0.3s timeout, never blocks)
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.3)
        s.connect(socket_path)
        s.sendall((json.dumps(payload) + '\\n').encode())
        s.close()
    except Exception:
        pass  # Always exit cleanly — never block the agent

    # Antigravity needs a decision on PreToolUse ({} reads as a denial). "ask" keeps its own
    # permission prompt (and the user's Always Allow); Coucou never allows a tool by itself.
    if agent == 'antigravity' and event == 'PreToolUse':
        sys.stdout.write('{"decision":"ask"}\\n')
        sys.stdout.flush()
    elif agent in ('gemini', 'antigravity', 'muse', 'copilot'):
        sys.stdout.write('{}\\n')
        sys.stdout.flush()

try:
    main()
except Exception:
    pass
sys.exit(0)
"""

// MARK: - nb-hook Python relay (App Store — socket in sandboxed container)

private let nbHookPythonAppStore = """
#!/usr/bin/env python3
# nb-hook.py — Coucou (App Store) hook relay for Claude Code and third-party agents
# Socket lives inside the sandboxed container; script runs outside the sandbox.
import sys, json, os, socket

def normalize_event(name):
    mapping = {
        'BeforeTool': 'PreToolUse', 'BeforeToolSelection': 'PreToolUse',
        'AfterTool': 'PostToolUse', 'AfterModel': 'PostToolUse',
        'BeforeAgent': 'UserPromptSubmit', 'AfterAgent': 'Stop',
        'startup': 'SessionStart', 'exit': 'SessionEnd',
        'PreInvocation': 'UserPromptSubmit', 'PostInvocation': 'PostToolUse',
        'pre_tool_use': 'PreToolUse', 'post_tool_use': 'PostToolUse',
        'user_prompt_submit': 'UserPromptSubmit', 'session_start': 'SessionStart',
        'session_end': 'SessionEnd', 'stop': 'Stop',
        'sessionStart': 'SessionStart', 'userPromptSubmitted': 'UserPromptSubmit',
        'agentStop': 'Stop', 'notification': 'Notification',
        'preToolUse': 'PreToolUse', 'postToolUse': 'PostToolUse',
        'permissionRequest': 'PermissionRequest', 'sessionEnd': 'SessionEnd',
    }
    return mapping.get(name, name)

def normalize_tool_fields(payload):
    if 'tool_name' not in payload:
        # Copilot sends toolName directly; other agents nest in toolCall
        if payload.get('toolName'):
            payload['tool_name'] = payload['toolName']
        else:
            tool = payload.get('toolCall')
            if not isinstance(tool, dict):
                tool = {}
            name = tool.get('name') or payload.get('tool', '')
            if name:
                payload['tool_name'] = name
    if 'tool_input' not in payload:
        # Copilot sends toolArgs directly
        tool_args = payload.get('toolArgs')
        if isinstance(tool_args, dict):
            payload['tool_input'] = tool_args
        else:
            tool = payload.get('toolCall') or {}
            if isinstance(tool.get('args'), dict):
                flat = dict(tool['args'])
                for src, dst in [('CommandLine', 'command'), ('FilePath', 'file_path'),
                                 ('Path', 'path'), ('Url', 'url'), ('Query', 'query'), ('Pattern', 'pattern')]:
                    if src in flat:
                        flat[dst] = flat[src]
                payload['tool_input'] = flat
    if 'session_id' not in payload:
        for k in ['conversationId', 'conversation_id', 'sessionId', 'GEMINI_SESSION_ID']:
            if payload.get(k):
                payload['session_id'] = payload[k]
                break
        if 'session_id' not in payload:
            sid = os.environ.get('GEMINI_SESSION_ID', '')
            if sid:
                payload['session_id'] = sid
    # Copilot sends workdir for the current working directory
    if not payload.get('cwd') and payload.get('workdir'):
        payload['cwd'] = payload['workdir']

def main():
    raw = b''
    payload = {}
    try:
        raw = sys.stdin.buffer.read()
        if not raw:
            if '--statusline' not in sys.argv[1:]:
                return
        else:
            payload = json.loads(raw)
    except Exception:
        if '--statusline' not in sys.argv[1:]:
            return

    socket_path = os.path.expanduser(
        '~/Library/Containers/fr.louisraille.Coucou/Data/nb.sock'
    )

    # --statusline mode: relay rate_limits to Coucou, then delegate to saved previous
    if '--statusline' in sys.argv[1:]:
        relay = {
            'coucou_kind': 'statusline',
            'session_id': payload.get('session_id', ''),
            'rate_limits': payload.get('rate_limits', {}),
        }
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(0.3)
            s.connect(socket_path)
            s.sendall((json.dumps(relay) + '\\n').encode())
            s.close()
        except Exception:
            pass
        prev_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'statusline-previous.json')
        if os.path.exists(prev_file):
            try:
                import subprocess
                with open(prev_file) as f:
                    prev = json.load(f)
                cmd = prev.get('command', '')
                if cmd:
                    result = subprocess.run(['/bin/sh', '-c', cmd], input=raw,
                                             capture_output=True, timeout=10)
                    if result.stdout:
                        sys.stdout.buffer.write(result.stdout)
                        sys.stdout.buffer.flush()
            except Exception:
                pass
        return

    # --ask mode: dedicated hook for AskUserQuestion via PreToolUse (Claude Code 2.1.85+)
    if '--ask' in sys.argv[1:]:
        tool = payload.get('tool_name', '')
        if tool != 'AskUserQuestion':
            return  # Not an AskUserQuestion invocation — exit cleanly (no output)
        payload['coucou_kind'] = 'ask_user_question'
        env = os.environ
        payload.setdefault('term_program', env.get('TERM_PROGRAM', ''))
        payload.setdefault('iterm_session_id', env.get('ITERM_SESSION_ID', ''))
        payload.setdefault('term_session_id', env.get('TERM_SESSION_ID', ''))
        payload.setdefault('bundle_id', env.get('__CFBundleIdentifier', ''))
        if 'cwd' not in payload or not payload['cwd']:
            paths = payload.get('workspacePaths') or payload.get('workspace_roots', [])
            if isinstance(paths, list) and paths:
                payload['cwd'] = paths[0]
            else:
                payload['cwd'] = os.getcwd()
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(125)
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
                if decision == 'answer':
                    answers = resp_obj.get('answers', {})
                    questions = payload.get('tool_input', {}).get('questions', [])
                    out = {'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': 'allow', 'updatedInput': {'questions': questions, 'answers': answers}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                # 'ask' or unknown: fall through → no output → Claude Code asks in terminal
        except Exception:
            pass
        return

    # Parse --agent <name> and optional positional event from argv.
    # --agent tags the payload with coucou_agent so the app routes to the right pill.
    # The positional arg is a fallback event name for agents that do not set hook_event_name.
    args = sys.argv[1:]
    agent = ''
    arg_event = ''
    i = 0
    while i < len(args):
        if args[i] == '--agent' and i + 1 < len(args):
            agent = args[i + 1]
            i += 2
        else:
            if not arg_event:
                arg_event = args[i]
            i += 1
    if agent:
        payload.setdefault('coucou_agent', agent)
    # Claude Code sessions from the Claude desktop app (Code tab) report this entrypoint;
    # route them to the Claude Desktop pill instead of dropping them (no VS Code terminal).
    if not payload.get('coucou_agent') and os.environ.get('CLAUDE_CODE_ENTRYPOINT') == 'claude-desktop':
        payload['coucou_agent'] = 'claude-desktop'

    env = os.environ
    payload.setdefault('term_program', env.get('TERM_PROGRAM', ''))
    payload.setdefault('iterm_session_id', env.get('ITERM_SESSION_ID', ''))
    payload.setdefault('term_session_id', env.get('TERM_SESSION_ID', ''))
    payload.setdefault('bundle_id', env.get('__CFBundleIdentifier', ''))
    if 'cwd' not in payload or not payload['cwd']:
        paths = payload.get('workspacePaths') or payload.get('workspace_roots', [])
        if isinstance(paths, list) and paths:
            payload['cwd'] = paths[0]
        else:
            payload['cwd'] = os.getcwd()

    # Normalize event name and tool fields (Gemini CLI / Antigravity → canonical names)
    try:
        raw_event = payload.get('hook_event_name', '') or arg_event
        if raw_event:
            payload['hook_event_name'] = normalize_event(raw_event)
        normalize_tool_fields(payload)
    except Exception:
        pass

    event = payload.get('hook_event_name', '')
    # socket_path is already defined above

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
                if agent == 'hermes':
                    hermes_choice = 'once' if decision == 'allow' else decision
                    if hermes_choice in ('once', 'always', 'deny'):
                        sys.stdout.write(json.dumps({'choice': hermes_choice}) + '\\n')
                        sys.stdout.flush()
                    sys.exit(0)
                if decision in ('allow', 'always'):
                    # Copilot/Muse use {"permissionDecision":"allow"} directly
                    if agent in ('copilot', 'muse'):
                        out = {'permissionDecision': 'allow'}
                    elif decision == 'always' and agent != 'codex':
                        # Let Claude Code persist the rule via updatedPermissions
                        suggestions = payload.get('permission_suggestions', [])
                        out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow', 'updatedPermissions': suggestions}}}
                    else:
                        # Claude Code / Codex plain allow
                        out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'deny':
                    if agent in ('copilot', 'muse'):
                        out = {'permissionDecision': 'deny'}
                    else:
                        out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'deny', 'message': 'Denied from Coucou'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'answer':
                    # AskUserQuestion answered from the notch
                    answers = resp_obj.get('answers', {})
                    questions = payload.get('tool_input', {}).get('questions', [])
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow', 'updatedInput': {'questions': questions, 'answers': answers}}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                # 'ask' or unknown: fall through → no output → agent re-asks
        except Exception:
            pass
        # App unreachable, timed out, or no explicit decision — print nothing
        # Copilot is fail-closed: must always output valid JSON so it re-asks rather than deny
        # Hermes: no output → json.loads raises in plugin → transport_fallback: builtin activates
        if agent == 'copilot':
            sys.stdout.write('{"permissionDecision":"ask"}\\n')
            sys.stdout.flush()
        sys.exit(0)

    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.3)
        s.connect(socket_path)
        s.sendall((json.dumps(payload) + '\\n').encode())
        s.close()
    except Exception:
        pass  # Always exit cleanly — never block the agent

    # Antigravity needs a decision on PreToolUse ({} reads as a denial). "ask" keeps its own
    # permission prompt (and the user's Always Allow); Coucou never allows a tool by itself.
    if agent == 'antigravity' and event == 'PreToolUse':
        sys.stdout.write('{"decision":"ask"}\\n')
        sys.stdout.flush()
    elif agent in ('gemini', 'antigravity', 'muse', 'copilot'):
        sys.stdout.write('{}\\n')
        sys.stdout.flush()

try:
    main()
except Exception:
    pass
sys.exit(0)
"""
