import Foundation

@MainActor
protocol AgentRuntimeAdapter: AnyObject {
    var id: AgentRuntimeID { get }
    var capabilities: AgentRuntimeCapabilities { get }
    var events: AsyncStream<AgentEvent> { get }

    func detectAvailability() async -> RuntimeAvailability
    func connect() async throws
    func disconnect() async
    func listModels() async throws -> [ModelDescriptor]
    func listSessions() async throws -> [AgentSession]
    func startSession(_ request: StartAgentSessionRequest) async throws -> AgentSession
    func resumeSession(id: String) async throws -> AgentSession
    func interrupt(sessionID: String) async throws
    func resolveApproval(
        sessionID: String,
        requestID: String,
        decision: ApprovalDecision
    ) async throws
    func respondToUserInput(
        sessionID: String,
        requestID: String,
        answers: [String: [String]]
    ) async throws
}

@MainActor
protocol AgentRuntimeEventIngress: AnyObject {
    func ingest(_ event: AgentEvent)
}

@MainActor
protocol AgentRuntimeStatusReporting: AnyObject {
    var statusUpdates: AsyncStream<RuntimeAvailability> { get }
}

@MainActor
protocol AgentConversationRuntimeAdapter: AnyObject {
    func loadConversation(sessionID: String) async throws -> [AgentConversationMessage]
    func sendPrompt(sessionID: String, prompt: String, model: ModelSelection?) async throws
}

protocol AIProvider: Sendable {
    var id: ProviderID { get }
    var capabilities: ProviderCapabilities { get }

    func authenticationStatus() async -> AuthenticationStatus
    func listModels(forceRefresh: Bool) async throws -> [ModelDescriptor]
    func chat(_ request: ChatRequest) async throws -> ChatResponse
    func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<ChatDelta, Error>
}

@MainActor
final class AgentRuntimeRegistry {
    private var adapters: [AgentRuntimeID: any AgentRuntimeAdapter] = [:]

    func register(_ adapter: any AgentRuntimeAdapter) {
        adapters[adapter.id] = adapter
    }

    func unregister(_ id: AgentRuntimeID) {
        adapters.removeValue(forKey: id)
    }

    func adapter(for id: AgentRuntimeID) -> (any AgentRuntimeAdapter)? {
        adapters[id]
    }

    var registeredRuntimeIDs: [AgentRuntimeID] {
        AgentRuntimeID.allCases.filter { adapters[$0] != nil }
    }
}

actor ProviderRegistry {
    private var providers: [ProviderID: any AIProvider] = [:]

    init(providers: [any AIProvider] = []) {
        for provider in providers {
            self.providers[provider.id] = provider
        }
    }

    func register(_ provider: any AIProvider) {
        providers[provider.id] = provider
    }

    func unregister(_ id: ProviderID) {
        providers.removeValue(forKey: id)
    }

    func provider(for id: ProviderID) -> (any AIProvider)? {
        providers[id]
    }

    var registeredProviderIDs: [ProviderID] {
        ProviderID.allCases.filter { providers[$0] != nil }
    }
}
