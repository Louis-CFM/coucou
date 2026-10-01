import Foundation

@MainActor
final class GeminiCLIAgentRuntimeAdapter: AgentRuntimeAdapter, AgentRuntimeEventIngress {
    let id: AgentRuntimeID = .geminiCLI
    let capabilities = AgentRuntimeCapabilities(
        observeSessions: true,
        startSession: false,
        resumeSession: false,
        interrupt: false,
        approvals: false,
        userInputRequests: false,
        toolEvents: true,
        fileChanges: false,
        commandEvents: false,
        subagents: false,
        runtimeModelSelection: false,
        runtimeReasoningSelection: false
    )
    let events: AsyncStream<AgentEvent>

    private let eventContinuation: AsyncStream<AgentEvent>.Continuation

    init() {
        let pair = AsyncStream<AgentEvent>.makeStream()
        events = pair.stream
        eventContinuation = pair.continuation
    }

    func detectAvailability() async -> RuntimeAvailability { .available(version: nil) }
    func connect() async throws {}
    func disconnect() async {}
    func listModels() async throws -> [ModelDescriptor] { [] }
    func listSessions() async throws -> [AgentSession] { [] }

    func startSession(_ request: StartAgentSessionRequest) async throws -> AgentSession {
        throw AgentRuntimeError.unsupportedFeature("Starting Gemini CLI sessions")
    }

    func resumeSession(id: String) async throws -> AgentSession {
        throw AgentRuntimeError.unsupportedFeature("Resuming Gemini CLI sessions")
    }

    func interrupt(sessionID: String) async throws {
        throw AgentRuntimeError.unsupportedFeature("Interrupting Gemini CLI sessions")
    }

    func resolveApproval(
        sessionID: String,
        requestID: String,
        decision: ApprovalDecision
    ) async throws {
        throw AgentRuntimeError.unsupportedFeature("Gemini CLI approvals")
    }

    func respondToUserInput(
        sessionID: String,
        requestID: String,
        answers: [String: [String]]
    ) async throws {
        throw AgentRuntimeError.unsupportedFeature("Answering Gemini CLI questions in Coucou")
    }

    func ingest(_ event: AgentEvent) {
        guard event.runtime == id else { return }
        eventContinuation.yield(event)
    }
}
