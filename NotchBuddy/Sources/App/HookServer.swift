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
    private var questionPillId: String = ""           // pill that owns the pending question
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
        let fd = pendingQuestionFD
        pendingQuestionFD = -1
        let source = questionFDSource
        questionFDSource = nil
        if fd >= 0, let data = try? JSONSerialization.data(withJSONObject: ["permissionDecision": "answer", "answers": answers], options: .withoutEscapingSlashes),
           let json = String(data: data, encoding: .utf8) {
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: json)
                DispatchQueue.main.async { source?.cancel() }
            }
        } else {
            source?.cancel()
        }
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
        } else if eventName == "beforeShellExecution" {
            // Cursor Agent shell gate — hold fd until Allow / Deny / Always (or timeout deny)
            Task { @MainActor in self.processCursorShellPermission(fd: fd, payload: payload) }
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
        // • "cursor" / Cursor bundle ID → agent_cursor (native Agent hooks or Claude Code in Cursor)
        // • other valid coucou_agent → external pill (fire-and-forget, no approval card)
        // • VS Code → integration_claude
        #if !APPSTORE
        let isCodexEvent = rawAgent == "codex"
        let isCursorAgentEvent = rawAgent == "cursor"
        #else
        let isCodexEvent = false
        let isCursorAgentEvent = false
        #endif
        let agentId: String
        let isExternalAgent: Bool
        if isCodexEvent {
            agentId = "agent_codex"
            isExternalAgent = false
        } else if isCursorAgentEvent || isCursorEditor {
            agentId = "agent_cursor"
            isExternalAgent = false
        } else if let agent = validAgent {
            agentId = "agent_\(agent)"
            isExternalAgent = true
        } else if isVSCodeEditor {
            agentId = "integration_claude"
            isExternalAgent = false
        } else {
            nbLog("Ignored \(name) from \(termProgram.isEmpty ? bundleId : termProgram) (\(projectName))")
            return
        }

        let focused = state.focusId == agentId

        // While a permission request is pending, dismiss when the resolving event arrives,
        // then continue normal processing. Only skip normal processing when unresolved.
        if let pending = state.pendingApproval, agentId == pending.pillId {
            let handledNote: String
            switch pending.pillId {
            case "agent_cursor": handledNote = "Handled in Cursor."
            case "agent_codex":  handledNote = "Handled in Codex."
            default:             handledNote = "Handled in VS Code."
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

        switch name {

        case "SessionStart":
            activeSessionId = sessionId
            if isExternalAgent { upsertExternalAgent(id: agentId, name: validAgent!) } else { upsertWorkspaceTask(id: agentId, projectName: projectName, cwd: cwd) }
            if let idx = state.tasks.firstIndex(where: { $0.id == agentId }) { state.tasks[idx].finalLine = nil }
            if state.focusId != agentId { state.setFocus(agentId) }
            nbLog("SessionStart \(isExternalAgent ? agentId : projectName) (\(sessionId.prefix(8)))")
            expandIfNeeded(to: .overview)
            SoundEngine.shared.play("work")

        case "UserPromptSubmit":
            activeSessionId = sessionId
            if isExternalAgent { upsertExternalAgent(id: agentId, name: validAgent!) } else { upsertWorkspaceTask(id: agentId, projectName: projectName, cwd: cwd) }
            if let idx = state.tasks.firstIndex(where: { $0.id == agentId }) { state.tasks[idx].finalLine = nil }
            state.updateTask(id: agentId, state: .thinking)
            if state.focusId != agentId { state.setFocus(agentId) }
            if let prompt = payload["prompt"] as? String, !prompt.isEmpty {
                appendStep(id: agentId, step: String(prompt.prefix(60)))
            }
            expandIfNeeded(to: .overview)

        case "PreToolUse":
            activeSessionId = sessionId
            let tool = payload["tool_name"] as? String ?? "Tool"
            if let idx = state.tasks.firstIndex(where: { $0.id == agentId }) { state.tasks[idx].finalLine = nil }
            // AskUserQuestion is handled via the dedicated --ask hook.
            // Skip state/step update here to avoid flickering over the question card.
            guard tool != "AskUserQuestion" else { break }
            if isExternalAgent { upsertExternalAgent(id: agentId, name: validAgent!) } else { upsertWorkspaceTask(id: agentId, projectName: projectName, cwd: cwd) }
            state.updateTask(id: agentId, state: .working)
            if state.focusId != agentId { state.setFocus(agentId) }
            let input = payload["tool_input"] as? [String: Any] ?? [:]
            // Live diff only for Edit/MultiEdit here. Full-file Write dumps (+hundreds of
            // green lines) kill the typewriter feel — wait for afterFileEdit / PostToolUse.
            if (tool == "Edit" || tool == "MultiEdit"),
               let diff = buildFileDiff(tool: tool, input: input, pillId: agentId) {
                if state.autoExpandProgramming {
                    presentLiveDiff(diff, agentId: agentId)
                } else {
                    let idx = state.appendSessionDiff(diff, for: agentId, autoOpen: false)
                    let step = String.makeDiffStep(filename: diff.name, added: diff.added,
                                                   removed: diff.removed, diffId: idx)
                    appendStep(id: agentId, step: step)
                    if state.view != .programming { expandIfNeeded(to: .overview) }
                }
            } else {
                let step = toolStep(tool: tool, input: input)
                appendStep(id: agentId, step: step)
                // Stay on the programming editor if it's already open — don't bounce to overview.
                if state.view != .programming {
                    expandIfNeeded(to: .overview)
                }
            }
            nbLog("PreToolUse \(tool)")

        case "PostToolUse":
            if isExternalAgent { upsertExternalAgent(id: agentId, name: validAgent!) }
            else { upsertWorkspaceTask(id: agentId, projectName: projectName, cwd: cwd) }
            state.updateTask(id: agentId, state: .working)
            if state.focusId != agentId { state.setFocus(agentId) }
            // Live diff: Edit / MultiEdit / afterFileEdit. Skip huge Write→fromNew dumps.
            let diffTool = payload["tool_name"] as? String ?? ""
            let diffInput = payload["tool_input"] as? [String: Any] ?? [:]
            if let diff = buildFileDiff(tool: diffTool, input: diffInput, pillId: agentId),
               shouldAutoOpenLiveDiff(diff) {
                if state.autoExpandProgramming {
                    presentLiveDiff(diff, agentId: agentId)
                } else {
                    let idx = state.appendSessionDiff(diff, for: agentId, autoOpen: false)
                    let step = String.makeDiffStep(filename: diff.name, added: diff.added,
                                                   removed: diff.removed, diffId: idx)
                    appendStep(id: agentId, step: step)
                    if state.focusId != agentId { setPillBadge(id: agentId, badge: .finished) }
                    expandIfNeeded(to: .overview)
                }
                nbLog("PostToolUse live-diff \(diffTool) \(diff.name) +\(diff.added)/−\(diff.removed)")
            } else {
                if state.view != .programming {
                    expandIfNeeded(to: .overview)
                }
                nbLog("PostToolUse \(diffTool.isEmpty ? "—" : diffTool)")
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
            let summary = state.sessionDiffSummary(for: agentId)
            let display: String = {
                if let summary, !finalText.isEmpty { return "\(summary) · \(finalText)" }
                if let summary { return summary }
                return finalText
            }()
            if !display.isEmpty {
                appendStep(id: agentId, step: display)
                if let idx = state.tasks.firstIndex(where: { $0.id == agentId }) {
                    state.tasks[idx].finalLine = display
                }
            }
            Self.recordFinishedSession(agentId: agentId, outcome: "ok",
                                       finalLine: display.isEmpty ? nil : display,
                                       summary: summary)
            SoundEngine.shared.play("finish")
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
            if focused && state.autoExpandFinished {
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
            state.updateTask(id: agentId, state: .error)
            let summary = state.sessionDiffSummary(for: agentId)
            Self.recordFinishedSession(agentId: agentId, outcome: "error",
                                       finalLine: nil, summary: summary)
            SoundEngine.shared.play("error")
            if focused && state.autoExpandFinished {
                expandIfNeeded(to: .error)
            } else {
                setPillBadge(id: agentId, badge: .error)
            }

        case "Interrupt":
            // Codex: user stopped the turn
            activeSessionId = nil
            state.updateTask(id: agentId, state: .idle)
            clearPillBadge(id: agentId)

        case "SessionEnd":
            activeSessionId = nil
            if let idx = state.tasks.firstIndex(where: { $0.id == agentId }) { state.tasks[idx].finalLine = nil }
            // Soft-retain diffs ~1h so open-last-file / recent files still work after the session ends.
            state.scheduleSoftClearSessionDiffs(for: agentId)
            state.removeTask(id: agentId)

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
        let color = IslandConst.colorForProject(name)
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

    /// True when the diff is small enough that the typewriter card is readable.
    /// Full-file Write dumps (isNewFile with dozens of lines) stay ticker-only.
    private func shouldAutoOpenLiveDiff(_ diff: FileDiff) -> Bool {
        if diff.tooLarge { return false }
        let churn = diff.added + diff.removed
        if diff.isNewFile { return churn > 0 && churn <= 40 }
        return churn > 0 && churn <= 200
    }

    /// Focus + force-expand the tall programming editor + auto-open the live diff.
    @MainActor
    private func presentLiveDiff(_ diff: FileDiff, agentId: String) {
        let state = AppState.shared
        if state.focusId != agentId { state.setFocus(agentId) }
        // Skip duplicate: same path + same +/- already the latest for this pill
        if let last = state.sessionDiffs[agentId]?.last,
           last.path == diff.path, last.added == diff.added, last.removed == diff.removed {
            state.pendingOpenDiff = (agentId, last.id)
            openProgrammingEditor()
            return
        }
        let idx = state.appendSessionDiff(diff, for: agentId, autoOpen: true)
        let step = String.makeDiffStep(filename: diff.name, added: diff.added, removed: diff.removed, diffId: idx)
        appendStep(id: agentId, step: step)
        openProgrammingEditor()
    }

    /// Expand (or switch) to the tall programming editor and keep it open briefly.
    @MainActor
    private func openProgrammingEditor() {
        let state = AppState.shared
        // Hold open so click-outside / auto-close don't kill the editor mid-typewriter.
        state.isPinned = true
        if state.mode == .expanded {
            state.view = .programming
        }
        NotificationCenter.default.post(name: .hookExpand, object: IslandView.programming)
        // Soft unpin after the typewriter has had time to play (user can re-pin).
        DispatchQueue.main.asyncAfter(deadline: .now() + 18) {
            if AppState.shared.view == .programming {
                AppState.shared.isPinned = false
            }
        }
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

        // Codex gets the same approval card as Claude Code / Cursor (GitHub build only).
        // Other external agents (any other coucou_agent) answer immediately with "ask"
        // so the agent re-asks in its own terminal — they do not get a notch card.
        #if !APPSTORE
        let isCodexRequest = rawAgent == "codex"
        #else
        let isCodexRequest = false
        #endif
        if !isCodexRequest && Self.validateAgent(rawAgent) != nil {
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
        } else if isCursorEditor {
            pillId = "agent_cursor"
        } else {
            pillId = "integration_claude"
        }
        guard isCodexRequest || isCursorEditor || isVSCodeEditor else {
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

        upsertWorkspaceTask(id: pillId, projectName: projectName, cwd: cwd)
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
            case "agent_cursor": note = "Handled in Cursor."
            case "agent_codex":  note = "Handled in Codex."
            default:             note = "Handled in VS Code."
            }
            self.dismissApprovalCard(note: note)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        approvalFDSource = source

        // 115s safety timeout — show a note and cancel without sending a decision.
        // nb-hook reads EOF from the cancel handler's close and exits; Claude Code / Codex re-asks.
        let captured = fd
        DispatchQueue.main.asyncAfter(deadline: .now() + 115) { [weak self] in
            guard let self, self.pendingApprovalFD == captured else { return }
            let note: String
            switch capturedPillId {
            case "agent_cursor": note = "Still waiting in Cursor."
            case "agent_codex":  note = "Still waiting in Codex."
            default:             note = "Still waiting in VS Code."
            }
            self.dismissApprovalCard(note: note)
        }
    }

    /// Called by ApprovalView buttons. Writes the decision to the waiting nb-hook and cleans up.
    @MainActor
    func sendApprovalDecision(_ decision: String) {
        let state = AppState.shared
        let approval = state.pendingApproval
        let pillId = approval?.pillId ?? "integration_claude"

        // Cursor Always → Coucursor allowlist (Cursor has no updatedPermissions).
        if decision == "always", approval?.isCursorShell == true {
            CursorShellAllowlist.add(cwd: approval?.inputKey ?? "", command: approval?.command ?? "")
        }

        let fd = pendingApprovalFD
        pendingApprovalFD = -1
        // Capture source before nulling — we send the decision first, then cancel the source.
        // The cancel handler closes the fd; never close it directly.
        let source = approvalFDSource
        approvalFDSource = nil

        // For Cursor shell Always, the relay maps "always" → permission allow.
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
        state.view = state.tasks.isEmpty ? .empty : .overview
    }

    // MARK: - Cursor shell permission (beforeShellExecution)

    /// Blocking gate for Cursor Agent shell commands. Reuses ApprovalView; Always uses Coucursor allowlist.
    @MainActor
    private func processCursorShellPermission(fd: Int32, payload: [String: Any]) {
        let state = AppState.shared
        let rawAgent = payload["coucou_agent"] as? String ?? ""
        guard rawAgent == "cursor" else {
            // Not our Cursor agent hook — deny closed so Cursor doesn't run blind.
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: #"{"permissionDecision":"deny"}"#)
                close(fd)
            }
            return
        }

        let sessionId = payload["session_id"] as? String
                     ?? payload["conversation_id"] as? String
                     ?? "unknown"
        var cwd = payload["cwd"] as? String ?? ""
        if cwd.isEmpty {
            let roots = payload["workspace_roots"] as? [String]
                     ?? payload["workspaceRoots"] as? [String]
            cwd = roots?.first ?? ""
        }
        let command = (payload["command"] as? String)
            ?? (payload["tool_input"] as? [String: Any])?["command"] as? String
            ?? "shell"
        let projectName = aliasProjectName(
            URL(fileURLWithPath: cwd).lastPathComponent.isEmpty
                ? "Cursor" : URL(fileURLWithPath: cwd).lastPathComponent
        )
        let pillId = "agent_cursor"
        nbLog("beforeShellExecution \(command.prefix(80)) [\(pillId)]")

        // Always allowlist hit — approve without a card.
        if CursorShellAllowlist.contains(cwd: cwd, command: command) {
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: #"{"permissionDecision":"allow"}"#)
                close(fd)
            }
            return
        }

        if pendingApprovalFD >= 0 {
            let old = pendingApprovalFD
            let oldSource = approvalFDSource
            approvalFDSource = nil
            let wasCursor = state.pendingApproval?.isCursorShell == true
            Task.detached { [weak self] in
                // Displace prior: Cursor shell → deny; Claude → ask (re-prompt in terminal).
                let json = wasCursor
                    ? #"{"permissionDecision":"deny"}"#
                    : #"{"permissionDecision":"ask"}"#
                self?.sendLine(fd: old, text: json)
                DispatchQueue.main.async { oldSource?.cancel() }
            }
        }
        pendingApprovalFD = fd
        activeSessionId = sessionId

        upsertWorkspaceTask(id: pillId, projectName: projectName, cwd: cwd)
        state.updateTask(id: pillId, state: .approval)
        // Store cwd in inputKey for Always allowlist fingerprint.
        state.pendingApproval = ApprovalInfo(
            sessionId: sessionId, tool: "Shell", command: command,
            inputKey: cwd, pillId: pillId, isCursorShell: true
        )
        state.isPinned = true
        SoundEngine.shared.play("approval")

        if focusBeforeApproval == nil { focusBeforeApproval = state.focusId }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.focusId = pillId }
        expandIfNeeded(to: .approval)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, self.pendingApprovalFD == fd else { return }
            self.dismissApprovalCard(note: "Handled in Cursor.")
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        approvalFDSource = source

        // Timeout → ask (Cursor’s own shell prompt), never silent deny / never auto-allow.
        let captured = fd
        let wait = TimeInterval(Self.cursorShellHookTimeoutSeconds - 10)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.pendingApprovalFD == captured else { return }
            self.sendApprovalDecision("ask")
            AppState.shared.noteMessage = "Shell wait timed out — approve in Cursor if it asks."
            AppState.shared.view = .note
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                NotificationCenter.default.post(name: .islandCollapse, object: nil)
            }
        }
    }

    @MainActor
    private static func recordFinishedSession(agentId: String, outcome: String,
                                              finalLine: String?, summary: String?) {
        let state = AppState.shared
        let name = state.tasks.first(where: { $0.id == agentId })?.name ?? agentId
        let paths = (state.sessionDiffs[agentId] ?? []).reversed().compactMap { d -> String? in
            d.path.isEmpty ? nil : d.path
        }
        var unique: [String] = []
        var seen = Set<String>()
        for p in paths where !seen.contains(p) {
            seen.insert(p)
            unique.append(p)
            if unique.count >= 5 { break }
        }
        SessionHistoryStore.shared.record(
            pillId: agentId, name: name, finalLine: finalLine,
            summary: summary, filePaths: unique, outcome: outcome
        )
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
        guard isCodexRequest || isCursorEditor || isVSCodeEditor else {
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

        upsertWorkspaceTask(id: pillId, projectName: projectName, cwd: cwd)
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

    /// Updates or transiently creates a workspace pill (VS Code or Cursor) task.
    /// If the task already exists (persistent), just updates name/cwd.
    /// If missing (transient), creates it and inserts after the main pill.
    @MainActor
    private func upsertWorkspaceTask(id: String, projectName: String, cwd: String = "") {
        let state = AppState.shared
        if let idx = state.tasks.firstIndex(where: { $0.id == id }) {
            state.tasks[idx].name = projectName
            if !cwd.isEmpty { state.tasks[idx].sessionCwd = cwd }
            return
        }
        // Transient: create and insert after the main pill
        let def = PillCatalog.definition(for: id)
        let color = def?.color ?? "#C0C4CC"
        let source = def?.source ?? .agent
        let task = AgentTask(id: id, name: projectName, color: color,
                             state: .idle, steps: [], source: source, isIntegration: true)
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

    // MARK: - Project name alias mapping

    private func aliasProjectName(_ name: String) -> String {
        let aliases: [String: String] = [
            "notch-buddy":  "Notch Buddy",
            "notchbuddy":   "Notch Buddy",
            "notch_buddy":  "Notch Buddy",
        ]
        return aliases[name.lowercased()] ?? name
    }

    // MARK: - Step labels (English)

    private func toolStep(tool: String, input: [String: Any]) -> String {
        let labels: [String: String] = [
            "Bash":         "Runs",
            "Shell":        "Runs",
            "Read":         "Reads",
            "Write":        "Writes",
            "Edit":         "Edits",
            "Glob":         "Finds",
            "Grep":         "Searches",
            "Delete":       "Deletes",
            "WebSearch":    "Web search",
            "WebFetch":     "Fetches",
            "TodoWrite":    "Tasks",
            "Task":         "Agent",
            "LS":           "Lists",
            "MultiEdit":    "Edits",
            "NotebookEdit": "Notebook",
            // Codex tools
            "apply_patch":  "Edits",
            "update_plan":  "Tasks",
            "spawn_agent":  "Agent",
        ]
        var label = labels[tool] ?? tool

        // Codex MCP tools arrive as mcp__server__tool — show "server · tool"
        if tool.hasPrefix("mcp__") {
            let rest = String(tool.dropFirst(5))
            let parts = rest.components(separatedBy: "__")
            label = parts.count >= 2 ? "\(parts[0]) · \(parts.dropFirst().joined(separator: "__"))" : rest
        }

        // Bash / Cursor Shell: infer a more precise verb from the command
        if tool == "Bash" || tool == "Shell", let cmd = input["command"] as? String {
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

    /// Infers an English verb from a shell command's first word.
    private func bashVerb(_ command: String) -> String {
        let first = command.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        switch first {
        case "cat", "bat", "head", "tail", "less", "more", "nl": return "Reads"
        case "rg", "grep", "find", "fd", "ls", "tree", "wc":    return "Finds"
        default: break
        }
        let testRunners = ["pytest", "vitest", "jest", "npm test", "npm run test",
                           "cargo test", "go test", "swift test", "make test",
                           "xcodebuild test", "unittest"]
        if testRunners.contains(where: { command.contains($0) }) { return "Tests" }
        return "Runs"
    }

    // MARK: - Live diff helpers

    @MainActor
    private func buildFileDiff(tool: String, input: [String: Any], pillId: String) -> FileDiff? {
        switch tool {
        case "Edit":
            let path = (input["file_path"] as? String) ?? (input["filePath"] as? String) ?? ""
            let old = (input["old_string"] as? String) ?? (input["oldString"] as? String) ?? ""
            let new = (input["new_string"] as? String) ?? (input["newString"] as? String) ?? ""
            guard !path.isEmpty, !old.isEmpty || !new.isEmpty else { return nil }
            let d = DiffEngine.fromEdit(old: old, new: new, path: path)
            return (d.added > 0 || d.removed > 0) ? d : nil

        case "MultiEdit":
            let path = (input["file_path"] as? String) ?? (input["filePath"] as? String) ?? ""
            guard !path.isEmpty,
                  let edits = input["edits"] as? [[String: Any]], !edits.isEmpty else { return nil }
            var totalAdded = 0, totalRemoved = 0, allHunks: [DiffHunk] = [], anyLarge = false
            for edit in edits {
                let old = (edit["old_string"] as? String) ?? (edit["oldString"] as? String)
                    ?? (edit["old_line"] as? String) ?? ""
                let new = (edit["new_string"] as? String) ?? (edit["newString"] as? String)
                    ?? (edit["new_line"] as? String) ?? ""
                guard !old.isEmpty || !new.isEmpty else { continue }
                let d = DiffEngine.fromEdit(old: old, new: new, path: path)
                totalAdded += d.added; totalRemoved += d.removed
                allHunks.append(contentsOf: d.hunks); if d.tooLarge { anyLarge = true }
            }
            guard totalAdded > 0 || totalRemoved > 0 else { return nil }
            return FileDiff(path: path, added: totalAdded, removed: totalRemoved,
                            hunks: allHunks, tooLarge: anyLarge, isNewFile: false)

        case "Write":
            let path = (input["file_path"] as? String)
                ?? (input["filePath"] as? String)
                ?? (input["path"] as? String)
                ?? ""
            let content = (input["content"] as? String)
                ?? (input["contents"] as? String)
                ?? ""
            guard !path.isEmpty, !content.isEmpty else { return nil }
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
        // Dedicated AskUserQuestion PreToolUse hook (Claude Code 2.1.85+, timeout 130s)
        var preToolUse = hooks["PreToolUse"] as? [[String: Any]] ?? []
        preToolUse.append([
            "matcher": "AskUserQuestion",
            "hooks": [["type": "command", "command": "\(quotedCmd) --ask", "timeout": 130]],
        ])
        hooks["PreToolUse"] = preToolUse
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
    private var _pendingPreviousData: Data?
    private var _pendingDeletePrevious: Bool = false

    /// Returns a diff string (only the statusLine key: before → after) without writing anything.
    func previewStatusLine(install: Bool) throws -> String {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        var settings: [String: Any] = [:]
        if let d = try? Data(contentsOf: settingsURL),
           let parsed = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            settings = parsed
        }
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
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let stamp = formatter.string(from: Date())
        let backupURL = settingsURL.deletingLastPathComponent()
            .appendingPathComponent("settings.json.bak-\(stamp)")
        try? FileManager.default.copyItem(at: settingsURL, to: backupURL)
        try? FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        try data.write(to: settingsURL, options: .atomic)
        // Commit side effects only after successful write
        if let prevData = _pendingPreviousData {
            try? prevData.write(to: statusLinePreviousURL, options: .atomic)
        }
        if _pendingDeletePrevious {
            try? FileManager.default.removeItem(at: statusLinePreviousURL)
        }
        _pendingStatusLineData = nil
        _pendingPreviousData = nil
        _pendingDeletePrevious = false
    }

    // MARK: - App Store: hooks via security-scoped bookmark

    #if APPSTORE
    /// Writes nb-hook script and updates settings.json in one shot.
    /// claudeURL must be a URL from NSOpenPanel (sandbox access is granted immediately — no security scope needed).
    func installAndWriteClaudeHooksAppStore(claudeURL: URL) throws {
        let data = try buildHooksData(claudeURL: claudeURL)

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
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let backupURL = claudeURL.appendingPathComponent("settings.json.bak-\(formatter.string(from: Date()))")
        try? FileManager.default.copyItem(at: settingsURL, to: backupURL)
        try data.write(to: settingsURL, options: .atomic)
        UserDefaults.standard.set(true, forKey: "coucouHooksInstalled")
    }

    func uninstallClaudeHooksAppStore(claudeURL: URL) throws {
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
        UserDefaults.standard.set(false, forKey: "coucouHooksInstalled")
    }

    private func buildHooksData(claudeURL: URL) throws -> Data {
        let settingsURL = claudeURL.appendingPathComponent("settings.json")
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = parsed
        }
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
        // Dedicated AskUserQuestion PreToolUse hook (Claude Code 2.1.85+, timeout 130s)
        var preToolUse = hooks["PreToolUse"] as? [[String: Any]] ?? []
        preToolUse.append([
            "matcher": "AskUserQuestion",
            "hooks": [["type": "command", "command": "\(quotedCmd) --ask", "timeout": 130]],
        ])
        hooks["PreToolUse"] = preToolUse
        settings["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
    }
    #endif

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

    // MARK: - Cursor Agent hook installer  (#if !APPSTORE only)

    static var cursorHooksURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor/hooks.json")
    }

    /// True when ~/.cursor/hooks.json already routes Cursor Agent events to Coucou's nb-hook.
    static func cursorHooksInstalled() -> Bool {
        guard let data = try? Data(contentsOf: cursorHooksURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return false }
        for value in hooks.values {
            guard let entries = value as? [[String: Any]] else { continue }
            for entry in entries {
                if let cmd = entry["command"] as? String,
                   cmd.contains("nb-hook"), cmd.contains("--agent cursor") { return true }
                // Nested group format (unlikely for Cursor, but tolerate it)
                if let inner = entry["hooks"] as? [[String: Any]] {
                    for hook in inner {
                        if let cmd = hook["command"] as? String,
                           cmd.contains("nb-hook"), cmd.contains("--agent cursor") { return true }
                    }
                }
            }
        }
        return false
    }

    /// Seconds Cursor waits on beforeShellExecution while the notch card is open.
    /// Must stay in sync with nb-hook.py socket timeout and the Swift safety timer.
    static let cursorShellHookTimeoutSeconds = 300

    /// True when beforeShellExecution is wired with a long enough wait (Allow/Deny).
    /// Older observe-only installs, or shell gates with a short timeout, need Update hooks.
    static func cursorShellHooksInstalled() -> Bool {
        guard let data = try? Data(contentsOf: cursorHooksURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any],
              let entries = hooks["beforeShellExecution"] as? [[String: Any]] else { return false }
        for entry in entries {
            if let cmd = entry["command"] as? String,
               cmd.contains("nb-hook"), cmd.contains("--agent cursor") {
                let timeout = entry["timeout"] as? Int ?? 0
                return timeout >= cursorShellHookTimeoutSeconds
            }
        }
        return false
    }

    private var _pendingCursorData: Data?
    private var _pendingCursorFingerprint: String?

    func previewCursorHooks(install: Bool) throws -> String {
        let url = Self.cursorHooksURL
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !install && !exists {
            throw NSError(domain: "CoucouNoop", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "No Cursor hooks to remove."
            ])
        }
        let current = exists ? try Data(contentsOf: url) : Data()
        _pendingCursorFingerprint = sha256Hex(current)
        let newData = install ? try buildCursorHooksData() : try withoutCursorHooks()
        _pendingCursorData = newData
        return String(data: newData, encoding: .utf8) ?? ""
    }

    func writeCursorHooks() throws {
        guard let data = _pendingCursorData, let fp = _pendingCursorFingerprint else {
            throw NSError(domain: "Coucou", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Nothing to write — click Install hooks again, then Confirm & write."
            ])
        }
        let url = Self.cursorHooksURL
        let current = (try? Data(contentsOf: url)) ?? Data()
        guard sha256Hex(current) == fp else {
            throw NSError(domain: "Coucou", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "~/.cursor/hooks.json changed since preview. Refresh and try again."
            ])
        }
        try writeJSONFile(data, to: url, suffix: "hooks.json")
        _pendingCursorData = nil
        _pendingCursorFingerprint = nil
    }

    private func buildCursorHooksData() throws -> Data {
        var root = try Self.strictReadJSONObject(at: Self.cursorHooksURL, label: "~/.cursor/hooks.json")
        if let raw = root["hooks"], !(raw is [String: Any]) {
            throw NSError(domain: "Coucou", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "~/.cursor/hooks.json: \"hooks\" has an unexpected type — Coucou has not touched it."
            ])
        }
        // Cursor requires version: 1
        if root["version"] == nil { root["version"] = 1 }
        let base = hookBase()
        // Observe the Agent loop + blocking beforeShellExecution for notch Allow/Deny.
        // Timeouts in seconds (Cursor format). Shell gate needs several minutes while the card is open.
        let shellWait = Self.cursorShellHookTimeoutSeconds
        let events: [(String, Int)] = [
            ("sessionStart",          10),
            ("sessionEnd",             5),
            ("beforeSubmitPrompt",    10),
            ("preToolUse",            10),
            ("postToolUse",           10),
            ("postToolUseFailure",    10),
            ("afterFileEdit",         10),
            ("stop",                  10),
            ("subagentStart",         10),
            ("subagentStop",          10),
            ("beforeShellExecution", shellWait),
        ]
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, timeout) in events {
            if let raw = hooks[event], !(raw is [[String: Any]]) {
                throw NSError(domain: "Coucou", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "~/.cursor/hooks.json: \"hooks\"[\"\(event)\"] has an unexpected type — Coucou has not touched it."
                ])
            }
            var entries = hooks[event] as? [[String: Any]] ?? []
            entries = removeNbHookEntries(from: entries)
            let hookEntry: [String: Any] = [
                "command": "\(base) --agent cursor",
                "timeout": timeout,
            ]
            entries.append(hookEntry)
            hooks[event] = entries
        }
        root["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: root,
                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private func withoutCursorHooks() throws -> Data {
        var root = try Self.strictReadJSONObject(at: Self.cursorHooksURL, label: "~/.cursor/hooks.json")
        if let raw = root["hooks"], !(raw is [String: Any]) {
            throw NSError(domain: "Coucou", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "~/.cursor/hooks.json: \"hooks\" has an unexpected type — Coucou has not touched it."
            ])
        }
        if var hooks = root["hooks"] as? [String: Any] {
            for key in hooks.keys {
                if let entries = hooks[key] as? [[String: Any]] {
                    let cleaned = removeNbHookEntries(from: entries)
                    if cleaned.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = cleaned }
                }
            }
            if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        }
        return try JSONSerialization.data(withJSONObject: root,
                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
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
if xcode-select -p >/dev/null 2>&1; then
    out=$(/usr/bin/python3 "$HOOK_DIR/nb-hook.py" "$@" 2>/dev/null)
    rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
        printf '%s\\n' "$out"
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
        # Cursor Agent (hooks.json camelCase)
        'sessionStart': 'SessionStart', 'sessionEnd': 'SessionEnd',
        'beforeSubmitPrompt': 'UserPromptSubmit',
        'preToolUse': 'PreToolUse', 'postToolUse': 'PostToolUse',
        'postToolUseFailure': 'PostToolUseFailure',
        'afterFileEdit': 'PostToolUse',
        'subagentStart': 'SubagentStart', 'subagentStop': 'SubagentStop',
        'stop': 'Stop',
        # beforeShellExecution kept as-is (blocking Cursor shell gate)
        'beforeShellExecution': 'beforeShellExecution',
    }
    return mapping.get(name, name)

def normalize_tool_fields(payload, raw_event=''):
    # Cursor afterFileEdit → MultiEdit shape for live diffs in the island
    if raw_event == 'afterFileEdit':
        path = payload.get('file_path') or payload.get('filePath') or ''
        raw_edits = payload.get('edits') if isinstance(payload.get('edits'), list) else []
        norm_edits = []
        for e in raw_edits:
            if not isinstance(e, dict):
                continue
            old = e.get('old_string') or e.get('oldString') or e.get('old_line') or ''
            new = e.get('new_string') or e.get('newString') or e.get('new_line') or ''
            if old or new:
                norm_edits.append({'old_string': old, 'new_string': new})
        payload['tool_name'] = 'MultiEdit'
        payload['tool_input'] = {'file_path': path, 'edits': norm_edits}
        payload['hook_event_name'] = 'PostToolUse'
    # Cursor beforeShellExecution → Shell tool shape for the notch card
    if raw_event == 'beforeShellExecution':
        cmd = payload.get('command', '') or ''
        payload['tool_name'] = 'Shell'
        payload['tool_input'] = {'command': cmd}
        payload['hook_event_name'] = 'beforeShellExecution'
    # Cursor stop status → Stop / StopFailure / Interrupt
    if raw_event == 'stop':
        status = payload.get('status', 'completed')
        if status == 'error':
            payload['hook_event_name'] = 'StopFailure'
        elif status == 'aborted':
            payload['hook_event_name'] = 'Interrupt'
        else:
            payload['hook_event_name'] = 'Stop'
    if 'session_id' not in payload:
        for k in ['conversationId', 'conversation_id', 'sessionId', 'GEMINI_SESSION_ID']:
            if payload.get(k):
                payload['session_id'] = payload[k]
                break
        if 'session_id' not in payload:
            sid = os.environ.get('GEMINI_SESSION_ID', '')
            if sid:
                payload['session_id'] = sid
    if 'tool_name' in payload:
        return
    tool = payload.get('toolCall')
    if not isinstance(tool, dict):
        tool = {}
    name = tool.get('name') or payload.get('tool', '')
    if name:
        payload['tool_name'] = name
    if 'tool_input' not in payload and isinstance(tool.get('args'), dict):
        flat = dict(tool['args'])
        for src, dst in [('CommandLine', 'command'), ('FilePath', 'file_path'),
                         ('Path', 'path'), ('Url', 'url'), ('Query', 'query'), ('Pattern', 'pattern')]:
            if src in flat:
                flat[dst] = flat[src]
        payload['tool_input'] = flat

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

    # Normalize event name and tool fields (Gemini / Antigravity / Cursor → canonical names)
    try:
        raw_event = payload.get('hook_event_name', '') or arg_event
        if raw_event:
            payload['hook_event_name'] = normalize_event(raw_event)
        normalize_tool_fields(payload, raw_event)
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
                    # Codex rejects updatedPermissions — answer a plain allow instead
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'deny':
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
        # Claude Code / Codex will handle the absence of output (re-ask or default behaviour)
        sys.exit(0)

    if event == 'beforeShellExecution' and agent == 'cursor':
        # Block until Coucursor Allow/Deny/Always. Emit Cursor permission JSON.
        # On timeout / app down → permission "ask" (Cursor UI), never hard-deny.
        def _cursor_shell_out(perm, msg=None):
            out = {'permission': perm}
            if msg:
                out['agentMessage'] = msg
                out['userMessage'] = msg
            sys.stdout.write(json.dumps(out) + '\\n')
            sys.stdout.flush()
            sys.exit(0)
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            # Keep under hooks.json beforeShellExecution timeout (300s).
            s.settimeout(290)
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
            decision = ''
            if response:
                try:
                    decision = json.loads(response).get('permissionDecision', '')
                except Exception:
                    decision = ''
            if decision in ('allow', 'always'):
                _cursor_shell_out('allow')
            if decision == 'deny':
                _cursor_shell_out('deny', 'Denied from Coucursor')
            if decision == 'ask':
                _cursor_shell_out('ask')
            _cursor_shell_out('ask')
        except Exception:
            _cursor_shell_out('ask')

    # All other events: fire-and-forget (0.3s timeout, never blocks)
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.3)
        s.connect(socket_path)
        s.sendall((json.dumps(payload) + '\\n').encode())
        s.close()
    except Exception:
        pass  # Always exit cleanly — never block the agent

    # Gemini CLI and Antigravity expect a JSON response on stdout (empty = no decision).
    # Cursor is fail-open with no stdout — do not emit {} (beforeSubmitPrompt could treat it as block).
    if agent in ('gemini', 'antigravity'):
        sys.stdout.write('{}\\n')
        sys.stdout.flush()

main()
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
        # Cursor Agent (hooks.json camelCase)
        'sessionStart': 'SessionStart', 'sessionEnd': 'SessionEnd',
        'beforeSubmitPrompt': 'UserPromptSubmit',
        'preToolUse': 'PreToolUse', 'postToolUse': 'PostToolUse',
        'postToolUseFailure': 'PostToolUseFailure',
        'afterFileEdit': 'PostToolUse',
        'subagentStart': 'SubagentStart', 'subagentStop': 'SubagentStop',
        'stop': 'Stop',
    }
    return mapping.get(name, name)

def normalize_tool_fields(payload, raw_event=''):
    # Cursor afterFileEdit → MultiEdit shape for live diffs in the island
    if raw_event == 'afterFileEdit':
        path = payload.get('file_path') or payload.get('filePath') or ''
        raw_edits = payload.get('edits') if isinstance(payload.get('edits'), list) else []
        norm_edits = []
        for e in raw_edits:
            if not isinstance(e, dict):
                continue
            old = e.get('old_string') or e.get('oldString') or e.get('old_line') or ''
            new = e.get('new_string') or e.get('newString') or e.get('new_line') or ''
            if old or new:
                norm_edits.append({'old_string': old, 'new_string': new})
        payload['tool_name'] = 'MultiEdit'
        payload['tool_input'] = {'file_path': path, 'edits': norm_edits}
        payload['hook_event_name'] = 'PostToolUse'
    # Cursor stop status → Stop / StopFailure / Interrupt
    if raw_event == 'stop':
        status = payload.get('status', 'completed')
        if status == 'error':
            payload['hook_event_name'] = 'StopFailure'
        elif status == 'aborted':
            payload['hook_event_name'] = 'Interrupt'
        else:
            payload['hook_event_name'] = 'Stop'
    if 'session_id' not in payload:
        for k in ['conversationId', 'conversation_id', 'sessionId', 'GEMINI_SESSION_ID']:
            if payload.get(k):
                payload['session_id'] = payload[k]
                break
        if 'session_id' not in payload:
            sid = os.environ.get('GEMINI_SESSION_ID', '')
            if sid:
                payload['session_id'] = sid
    if 'tool_name' in payload:
        return
    tool = payload.get('toolCall')
    if not isinstance(tool, dict):
        tool = {}
    name = tool.get('name') or payload.get('tool', '')
    if name:
        payload['tool_name'] = name
    if 'tool_input' not in payload and isinstance(tool.get('args'), dict):
        flat = dict(tool['args'])
        for src, dst in [('CommandLine', 'command'), ('FilePath', 'file_path'),
                         ('Path', 'path'), ('Url', 'url'), ('Query', 'query'), ('Pattern', 'pattern')]:
            if src in flat:
                flat[dst] = flat[src]
        payload['tool_input'] = flat

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

    # Normalize event name and tool fields (Gemini / Antigravity / Cursor → canonical names)
    try:
        raw_event = payload.get('hook_event_name', '') or arg_event
        if raw_event:
            payload['hook_event_name'] = normalize_event(raw_event)
        normalize_tool_fields(payload, raw_event)
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
                    # Codex rejects updatedPermissions — answer a plain allow instead
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'deny':
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
        sys.exit(0)

    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.3)
        s.connect(socket_path)
        s.sendall((json.dumps(payload) + '\\n').encode())
        s.close()
    except Exception:
        pass  # Always exit cleanly — never block the agent

    # Gemini CLI and Antigravity expect a JSON response on stdout (empty = no decision).
    # Cursor is fail-open with no stdout — do not emit {} (beforeSubmitPrompt could treat it as block).
    if agent in ('gemini', 'antigravity'):
        sys.stdout.write('{}\\n')
        sys.stdout.flush()

main()
sys.exit(0)
"""
