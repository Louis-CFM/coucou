import Foundation

@MainActor
final class ClaudeCodeAgentRuntimeAdapter: AgentRuntimeAdapter, AgentRuntimeEventIngress {
    let id: AgentRuntimeID = .claudeCode
    let capabilities = AgentRuntimeCapabilities(
        observeSessions: true,
        startSession: false,
        resumeSession: false,
        interrupt: false,
        approvals: true,
        userInputRequests: false,
        toolEvents: true,
        fileChanges: false,
        commandEvents: false,
        subagents: true,
        runtimeModelSelection: false,
        runtimeReasoningSelection: false
    )
    let events: AsyncStream<AgentEvent>

    private let eventContinuation: AsyncStream<AgentEvent>.Continuation
    private let approvalHandler: (ApprovalDecision) -> Void

    init(approvalHandler: @escaping (ApprovalDecision) -> Void = { decision in
        let nativeDecision = switch decision {
        case .allow: "allow"
        case .allowForSession: "always"
        case .deny: "deny"
        }
        HookServer.shared.sendApprovalDecision(nativeDecision)
    }) {
        let pair = AsyncStream<AgentEvent>.makeStream()
        events = pair.stream
        eventContinuation = pair.continuation
        self.approvalHandler = approvalHandler
    }

    func detectAvailability() async -> RuntimeAvailability {
        .available(version: nil)
    }

    func connect() async throws {}

    func disconnect() async {}

    func listModels() async throws -> [ModelDescriptor] { [] }

    func listSessions() async throws -> [AgentSession] { [] }

    func startSession(_ request: StartAgentSessionRequest) async throws -> AgentSession {
        throw AgentRuntimeError.unsupportedFeature("Starting Claude Code sessions")
    }

    func resumeSession(id: String) async throws -> AgentSession {
        throw AgentRuntimeError.unsupportedFeature("Resuming Claude Code sessions")
    }

    func interrupt(sessionID: String) async throws {
        throw AgentRuntimeError.unsupportedFeature("Interrupting Claude Code sessions")
    }

    func resolveApproval(
        sessionID: String,
        requestID: String,
        decision: ApprovalDecision
    ) async throws {
        approvalHandler(decision)
    }

    func respondToUserInput(
        sessionID: String,
        requestID: String,
        answers: [String: [String]]
    ) async throws {
        throw AgentRuntimeError.unsupportedFeature("Answering Claude Code questions in Coucou")
    }

    func ingest(_ event: AgentEvent) {
        guard event.runtime == id else { return }
        eventContinuation.yield(event)
    }
}
