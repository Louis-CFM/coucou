import Foundation
import Combine

@MainActor
final class AgentRuntimeManager: ObservableObject {
    private let registry = AgentRuntimeRegistry()
    private var eventTasks: [AgentRuntimeID: Task<Void, Never>] = [:]
    private var statusTasks: [AgentRuntimeID: Task<Void, Never>] = [:]
    private var lastSequenceBySession: [String: UInt64] = [:]
    private var processedNativeEventIDs: Set<String> = []
    private var processedNativeEventOrder: [String] = []

    @Published private(set) var availability: [AgentRuntimeID: RuntimeAvailability] = [:]
    @Published private(set) var models: [AgentRuntimeID: [ModelDescriptor]] = [:]
    @Published private(set) var sessions: [String: AgentSession] = [:]
    @Published private(set) var conversations: [String: [AgentConversationMessage]] = [:]
    @Published private(set) var conversationLoading: Set<String> = []
    @Published private(set) var latestAttentionSessionID: String?

    init(adapters: [any AgentRuntimeAdapter] = [
        ClaudeCodeAgentRuntimeAdapter(),
        CodexAgentRuntimeAdapter(),
        GeminiCLIAgentRuntimeAdapter(),
        AntigravityAgentRuntimeAdapter(),
    ]) {
        for adapter in adapters {
            registry.register(adapter)
        }
    }

    func start() async {
        for runtimeID in registry.registeredRuntimeIDs {
            guard let adapter = registry.adapter(for: runtimeID) else { continue }
            let detected = await adapter.detectAvailability()
            availability[runtimeID] = detected
            guard case .available = detected else { continue }

            do {
                try await adapter.connect()
                observe(adapter)
                observeStatus(adapter)
                models[runtimeID] = try await adapter.listModels()
                for session in try await adapter.listSessions() {
                    sessions[session.id] = session
                }
            } catch {
                availability[runtimeID] = .unavailable(reason: error.localizedDescription)
                await adapter.disconnect()
            }
        }
    }

    func stop() async {
        for task in eventTasks.values { task.cancel() }
        eventTasks.removeAll()
        for task in statusTasks.values { task.cancel() }
        statusTasks.removeAll()
        for runtimeID in registry.registeredRuntimeIDs {
            await registry.adapter(for: runtimeID)?.disconnect()
        }
    }

    func startSession(
        runtimeID: AgentRuntimeID,
        request: StartAgentSessionRequest
    ) async throws -> AgentSession {
        guard let adapter = registry.adapter(for: runtimeID) else {
            throw AgentRuntimeError.runtimeNotRegistered
        }
        let session = try await adapter.startSession(request)
        sessions[session.id] = session
        return session
    }

    func resumeSession(sessionID: String) async throws -> AgentSession {
        guard let existing = sessions[sessionID],
              let adapter = registry.adapter(for: existing.runtime) else {
            throw AgentRuntimeError.unknownSession
        }
        let session = try await adapter.resumeSession(id: existing.nativeSessionID)
        sessions[session.id] = session
        return session
    }

    func resolveApproval(
        sessionID: String,
        requestID: String,
        decision: ApprovalDecision
    ) async throws {
        guard let session = sessions[sessionID],
              let adapter = registry.adapter(for: session.runtime) else {
            throw AgentRuntimeError.unknownSession
        }
        guard session.pendingApproval?.id == requestID else {
            throw AgentRuntimeError.staleRequest
        }
        try await adapter.resolveApproval(
            sessionID: session.nativeSessionID,
            requestID: requestID,
            decision: decision
        )
    }

    func interrupt(sessionID: String) async throws {
        guard let session = sessions[sessionID],
              let adapter = registry.adapter(for: session.runtime) else {
            throw AgentRuntimeError.unknownSession
        }
        try await adapter.interrupt(sessionID: session.nativeSessionID)
    }

    func loadConversation(sessionID: String) async throws {
        guard let session = sessions[sessionID],
              let adapter = registry.adapter(for: session.runtime) as? any AgentConversationRuntimeAdapter else {
            throw AgentRuntimeError.unsupportedFeature("Viewing this runtime's conversation")
        }
        conversationLoading.insert(sessionID)
        defer { conversationLoading.remove(sessionID) }
        conversations[sessionID] = try await adapter.loadConversation(
            sessionID: session.nativeSessionID
        )
    }

    func sendPrompt(sessionID: String, prompt: String) async throws {
        guard var session = sessions[sessionID],
              let runtimeAdapter = registry.adapter(for: session.runtime),
              let conversationAdapter = runtimeAdapter as? any AgentConversationRuntimeAdapter else {
            throw AgentRuntimeError.unsupportedFeature("Continuing this runtime's conversation")
        }

        if session.state == .disconnected {
            session = try await runtimeAdapter.resumeSession(id: session.nativeSessionID)
            sessions[session.id] = session
        }

        try await conversationAdapter.sendPrompt(
            sessionID: session.nativeSessionID,
            prompt: prompt,
            model: session.model
        )
        let message = AgentConversationMessage(
            id: "local-\(UUID().uuidString)",
            role: .user,
            content: prompt,
            createdAt: Date()
        )
        conversations[sessionID, default: []].append(message)
        session.state = .working
        session.updatedAt = Date()
        sessions[sessionID] = session
    }

    func respondToUserInput(
        sessionID: String,
        requestID: String,
        answers: [String: [String]]
    ) async throws {
        guard let session = sessions[sessionID],
              let adapter = registry.adapter(for: session.runtime) else {
            throw AgentRuntimeError.unknownSession
        }
        guard session.pendingUserInput?.id == requestID else {
            throw AgentRuntimeError.staleRequest
        }
        try await adapter.respondToUserInput(
            sessionID: session.nativeSessionID,
            requestID: requestID,
            answers: answers
        )
    }

    func ingestExternal(_ event: AgentEvent) {
        guard let ingress = registry.adapter(for: event.runtime) as? any AgentRuntimeEventIngress else {
            return
        }
        ingress.ingest(event)
    }

    private func observe(_ adapter: any AgentRuntimeAdapter) {
        eventTasks[adapter.id]?.cancel()
        eventTasks[adapter.id] = Task { [weak self] in
            for await event in adapter.events {
                guard !Task.isCancelled else { return }
                self?.receive(event)
            }
        }
    }

    private func observeStatus(_ adapter: any AgentRuntimeAdapter) {
        guard let reporter = adapter as? any AgentRuntimeStatusReporting else { return }
        statusTasks[adapter.id]?.cancel()
        statusTasks[adapter.id] = Task { [weak self] in
            for await status in reporter.statusUpdates {
                guard !Task.isCancelled else { return }
                self?.availability[adapter.id] = status
            }
        }
    }

    private func receive(_ event: AgentEvent) {
        let normalizedID = "\(event.runtime.rawValue):\(event.sessionID)"
        if let sequence = event.sequence {
            if let last = lastSequenceBySession[normalizedID], sequence <= last { return }
            lastSequenceBySession[normalizedID] = sequence
        }
        if let nativeID = event.metadata["nativeEventID"]?.stringValue {
            let deduplicationKey = "\(event.runtime.rawValue):\(event.sessionID):\(nativeID)"
            guard processedNativeEventIDs.insert(deduplicationKey).inserted else { return }
            processedNativeEventOrder.append(deduplicationKey)
            if processedNativeEventOrder.count > 2_048 {
                let expired = Array(processedNativeEventOrder.prefix(512))
                processedNativeEventOrder.removeFirst(512)
                processedNativeEventIDs.subtract(expired)
            }
        }
        if sessions[normalizedID] == nil {
            sessions[normalizedID] = AgentSession(
                id: normalizedID,
                runtime: event.runtime,
                provider: event.provider,
                nativeSessionID: event.sessionID,
                workspace: event.metadata["cwd"]?.stringValue.map(URL.init(fileURLWithPath:)),
                state: .starting,
                model: nil,
                latestActivity: nil,
                pendingApproval: nil,
                pendingUserInput: nil,
                startedAt: event.timestamp,
                updatedAt: event.timestamp,
                metadata: [:]
            )
        }
        guard var session = sessions[normalizedID] else { return }
        AgentSessionReducer.reduce(&session, event: event)
        sessions[normalizedID] = session
        ingestConversationMessage(from: event, sessionID: normalizedID)
        latestAttentionSessionID = sessions.values
            .filter { $0.pendingApproval != nil || $0.pendingUserInput != nil }
            .max(by: { $0.updatedAt < $1.updatedAt })?
            .id
    }

    private func ingestConversationMessage(from event: AgentEvent, sessionID: String) {
        guard let item = event.metadata["item"]?.objectValue,
              let type = item["type"]?.stringValue,
              let id = item["id"]?.stringValue else { return }

        let message: AgentConversationMessage?
        switch type {
        case "agentMessage":
            message = item["text"]?.stringValue.map {
                AgentConversationMessage(id: id, role: .assistant, content: $0, createdAt: event.timestamp)
            }
        case "userMessage":
            let text = item["content"]?.arrayValue?
                .compactMap { $0["text"]?.stringValue }
                .joined(separator: "\n")
            message = text.map {
                AgentConversationMessage(id: id, role: .user, content: $0, createdAt: event.timestamp)
            }
        default:
            message = nil
        }
        guard let message, !message.content.isEmpty else { return }
        var items = conversations[sessionID, default: []]
        if let index = items.firstIndex(where: { $0.id == message.id }) {
            items[index] = message
        } else if !items.contains(where: { $0.role == message.role && $0.content == message.content }) {
            items.append(message)
        }
        conversations[sessionID] = items
    }
}
