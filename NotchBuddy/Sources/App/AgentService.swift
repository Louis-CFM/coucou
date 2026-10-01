import Foundation

// MARK: - AgentService
//
// Abstraction over a local agent environment (Claude Code via hooks, OpenCode via its
// HTTP/SSE API, …). A service owns its transport and the provider-specific payload
// parsing, then emits normalized AgentEvent values.
//
// Island state (pill, bot, ticker, badges, sounds, approval card) is only mutated by
// AgentEventRouter, so every provider drives the UI the same way.

// MARK: - Approval

/// Decision for a pending approval. `.ask` hands the question back to the agent's own
/// prompt (used on timeout) instead of answering on the user's behalf.
enum AgentApprovalDecision: Sendable {
    case allow, alwaysAllow, deny, ask
}

/// Normalized permission request shown by ApprovalView.
struct AgentPermissionRequest: Sendable {
    var sessionID: String
    var requestID: String   // provider correlation id — "" when the provider has none
    var tool: String
    var command: String
}

// MARK: - Events

/// What happened in the agent, normalized across providers.
enum AgentEventKind: Sendable {
    case sessionStart
    case userPrompt(String?)
    case working
    case step(String)                    // one already-formatted ticker line
    case stepFailure
    case notification(String)            // rate-limit / question raised by the provider
    case finished(String?)
    case failed(String?)
    case interrupted
    case sessionEnd(resetTo: String?)    // pill label restored after the session closes
    case subagentStart
    case subagentStop
    case permissionRequest(AgentPermissionRequest)
    case permissionResolved(AgentApprovalDecision)
}

/// An event plus the pill context needed to render it.
struct AgentEvent: Sendable {
    var taskID: String
    var projectName: String
    var cwd: String
    var kind: AgentEventKind

    init(taskID: String, projectName: String = "", cwd: String = "", kind: AgentEventKind) {
        self.taskID = taskID
        self.projectName = projectName
        self.cwd = cwd
        self.kind = kind
    }
}

// MARK: - AgentService protocol

@MainActor
protocol AgentService: AnyObject {
    /// Integration pill id (`AgentTask.id`) this service drives.
    var taskID: String { get }
    var source: AgentSource { get }
    /// True while ApprovalView shows a request owned by this service.
    var hasPendingApproval: Bool { get }
    func start()
    func respond(to decision: AgentApprovalDecision)
}

// MARK: - Registry

/// Keeps track of every agent service so shared UI (approval buttons) can find the
/// service that owns the pending request instead of hardcoding one provider.
@MainActor
final class AgentServiceRegistry {
    static let shared = AgentServiceRegistry()
    private var services: [any AgentService] = []

    private init() {}

    func register(_ service: any AgentService) {
        guard !services.contains(where: { $0.taskID == service.taskID }) else { return }
        services.append(service)
    }

    func service(for taskID: String) -> (any AgentService)? {
        services.first { $0.taskID == taskID }
    }

    /// Routes the approval card buttons to the service owning the pending request.
    /// No-op when nothing is pending — matching the pre-adapter behaviour.
    func approve(_ decision: AgentApprovalDecision) {
        services.first { $0.hasPendingApproval }?.respond(to: decision)
    }
}

// MARK: - Event router

/// Applies normalized agent events to AppState. Extracted from HookServer so that every
/// provider shares the same pill / bot / badge / sound behaviour.
@MainActor
final class AgentEventRouter {
    static let shared = AgentEventRouter()

    private init() {}

    /// Returns false when the target pill is not loaded (integration switched off),
    /// in which case the event is dropped entirely — no sound, no badge.
    @discardableResult
    func handle(_ event: AgentEvent) -> Bool {
        let state = AppState.shared
        let id = event.taskID
        guard state.tasks.contains(where: { $0.id == id }) else { return false }

        let focused = state.focusId == id

        switch event.kind {

        case .sessionStart:
            upsertTask(id: id, projectName: event.projectName, cwd: event.cwd)
            agentLog("\(id) SessionStart \(event.projectName)")
            if state.isPresent { expandIfNeeded(to: .overview) }
            SoundEngine.shared.play("work")

        case .userPrompt(let message):
            upsertTask(id: id, projectName: event.projectName, cwd: event.cwd)
            state.updateTask(id: id, state: .thinking)
            if let message, !message.isEmpty {
                appendStep(id: id, step: String(message.prefix(60)))
            }
            if state.isPresent { expandIfNeeded(to: .overview) }

        case .working:
            state.updateTask(id: id, state: .working)

        case .step(let label):
            upsertTask(id: id, projectName: event.projectName, cwd: event.cwd)
            state.updateTask(id: id, state: .working)
            appendStep(id: id, step: label)
            agentLog("\(id) step \(label)")

        case .stepFailure:
            state.updateTask(id: id, state: .working)
            appendStep(id: id, step: "⚠ failed")

        case .notification(let message):
            let lower = message.lowercased()
            if lower.contains("rate limit") || lower.contains("limite d") {
                state.updateTask(id: id, state: .ratelimit)
                SoundEngine.shared.play("rate")
            } else if message.hasSuffix("?") {
                state.updateTask(id: id, state: .question)
                appendStep(id: id, step: message)
            }

        case .finished(let message):
            state.updateTask(id: id, state: .finished)
            if let message, !message.isEmpty {
                appendStep(id: id, step: String(message.prefix(60)))
            }
            SoundEngine.shared.play("finish")
            if focused {
                expandIfNeeded(to: .finished)
            } else {
                setPillBadge(id: id, badge: .finished)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) {
                state.updateTask(id: id, state: .idle)
                self.clearPillBadge(id: id)
            }

        case .failed(let message):
            state.updateTask(id: id, state: .error)
            if let message, !message.isEmpty {
                appendStep(id: id, step: String(message.prefix(60)))
            }
            SoundEngine.shared.play("error")
            if focused {
                expandIfNeeded(to: .error)
            } else {
                setPillBadge(id: id, badge: .error)
            }

        case .interrupted:
            state.updateTask(id: id, state: .idle)
            clearPillBadge(id: id)

        case .sessionEnd(let resetTo):
            state.updateTask(id: id, state: .idle)
            clearSession(id: id, resetTo: resetTo)

        case .subagentStart:
            appendStep(id: id, step: "+ subagent")

        case .subagentStop:
            appendStep(id: id, step: "• subagent done")

        case .permissionRequest(let request):
            upsertTask(id: id, projectName: event.projectName, cwd: event.cwd)
            state.updateTask(id: id, state: .approval)
            state.pendingApproval = ApprovalInfo(sessionId: request.sessionID,
                                                 tool: request.tool,
                                                 command: request.command)
            state.isPinned = true
            SoundEngine.shared.play("approval")
            // Approval always forces the island open — user must be able to respond
            state.focusId = id
            expandIfNeeded(to: .approval)

        case .permissionResolved:
            state.pendingApproval = nil
            state.isPinned = false
            state.updateTask(id: id, state: .working)
            clearPillBadge(id: id)
            state.view = state.tasks.isEmpty ? .empty : .overview
        }

        return true
    }

    // MARK: - Helpers

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

    /// Renames the pill with the current session project and records its working directory.
    /// Only touches pills that already exist — never creates one.
    private func upsertTask(id: String, projectName: String, cwd: String) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        if !projectName.isEmpty { state.tasks[idx].name = projectName }
        if !cwd.isEmpty { state.tasks[idx].sessionCwd = cwd }
    }

    /// Resets the pill after a session ends: steps cleared, label restored.
    private func clearSession(id: String, resetTo: String?) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[idx].steps = []
        state.tasks[idx].stepIndex = 0
        if let resetTo { state.tasks[idx].name = resetTo }
        state.tasks[idx].pillBadge = nil
    }

    private func setPillBadge(id: String, badge: PillBadge) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[idx].pillBadge = badge
    }

    private func clearPillBadge(id: String) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[idx].pillBadge = nil
    }

    private func appendStep(id: String, step: String) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[idx].steps.append(step)
        if state.tasks[idx].steps.count > 20 { state.tasks[idx].steps.removeFirst() }
        state.tasks[idx].stepIndex = state.tasks[idx].steps.count - 1
    }
}

// MARK: - Logging

/// Appends a line to ~/Library/Logs/NotchBuddy/nb.log.
func agentLog(_ message: String) {
    let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/NotchBuddy")
    try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    let logFile = logsDir.appendingPathComponent("nb.log")
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(formatter.string(from: Date())) \(message)\n"
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
