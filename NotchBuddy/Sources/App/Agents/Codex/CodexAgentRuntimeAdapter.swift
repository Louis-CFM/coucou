import Foundation

@MainActor
final class CodexAgentRuntimeAdapter: AgentRuntimeAdapter, AgentRuntimeStatusReporting, AgentConversationRuntimeAdapter {
    let id: AgentRuntimeID = .codex
    let capabilities = AgentRuntimeCapabilities(
        observeSessions: true,
        startSession: true,
        resumeSession: true,
        interrupt: true,
        approvals: true,
        userInputRequests: true,
        toolEvents: true,
        fileChanges: true,
        commandEvents: true,
        subagents: true,
        runtimeModelSelection: true,
        runtimeReasoningSelection: true
    )
    let events: AsyncStream<AgentEvent>
    let statusUpdates: AsyncStream<RuntimeAvailability>

    private let eventContinuation: AsyncStream<AgentEvent>.Continuation
    private let statusContinuation: AsyncStream<RuntimeAvailability>.Continuation
    private var transport: CodexAppServerTransport?
    private var eventTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var activeTurnIDs: [String: String] = [:]
    private var knownSessionIDs: Set<String> = []
    private var eventSequence: UInt64 = 0
    private var isDisconnecting = false
    private var runtimeVersion: String?

    init() {
        let pair = AsyncStream<AgentEvent>.makeStream()
        events = pair.stream
        eventContinuation = pair.continuation
        let statusPair = AsyncStream<RuntimeAvailability>.makeStream()
        statusUpdates = statusPair.stream
        statusContinuation = statusPair.continuation
    }

    func detectAvailability() async -> RuntimeAvailability {
        guard let executable = CodexExecutableLocator.locate() else {
            return .unavailable(reason: "Codex CLI was not found")
        }
        let version = await Task.detached { CodexExecutableLocator.version(at: executable) }.value
        runtimeVersion = version
        return .available(version: version)
    }

    func connect() async throws {
        guard transport == nil else { return }
        guard let executable = CodexExecutableLocator.locate() else {
            throw CodexAppServerError.executableNotFound
        }
        isDisconnecting = false
        try await establishConnection(executableURL: executable)
    }

    func disconnect() async {
        isDisconnecting = true
        reconnectTask?.cancel()
        reconnectTask = nil
        eventTask?.cancel()
        eventTask = nil
        statusTask?.cancel()
        statusTask = nil
        await transport?.disconnect()
        transport = nil
        activeTurnIDs.removeAll()
    }

    func listModels() async throws -> [ModelDescriptor] {
        var models: [ModelDescriptor] = []
        var cursor: String?
        var seenCursors: Set<String> = []
        repeat {
            var params: [String: JSONValue] = ["includeHidden": .bool(false)]
            if let cursor { params["cursor"] = .string(cursor) }
            let result = try await connectedTransport().request(
                method: "model/list",
                params: .object(params)
            )
            models.append(contentsOf: CodexAppServerCodec.models(from: result))
            cursor = result["nextCursor"]?.stringValue
            if let cursor, !seenCursors.insert(cursor).inserted { break }
        } while cursor != nil
        return models
    }

    func listSessions() async throws -> [AgentSession] {
        var sessions: [AgentSession] = []
        var cursor: String?
        var seenCursors: Set<String> = []
        repeat {
            var params: [String: JSONValue] = ["limit": .number(100)]
            if let cursor { params["cursor"] = .string(cursor) }
            let result = try await connectedTransport().request(
                method: "thread/list",
                params: .object(params)
            )
            let page = CodexAppServerCodec.sessions(from: result)
            sessions.append(contentsOf: page)
            knownSessionIDs.formUnion(page.map(\.nativeSessionID))
            cursor = result["nextCursor"]?.stringValue
            if let cursor, !seenCursors.insert(cursor).inserted { break }
        } while cursor != nil
        return sessions
    }

    func startSession(_ request: StartAgentSessionRequest) async throws -> AgentSession {
        var params: [String: JSONValue] = [:]
        if let workspace = request.workspace { params["cwd"] = .string(workspace.path) }
        if let model = request.model?.modelID { params["model"] = .string(model) }

        let result = try await connectedTransport().request(
            method: "thread/start",
            params: .object(params)
        )
        guard var session = CodexAppServerCodec.session(fromThreadResponse: result) else {
            throw CodexAppServerError.invalidMessage
        }
        knownSessionIDs.insert(session.nativeSessionID)
        session.model = request.model ?? session.model

        if let prompt = request.prompt, !prompt.isEmpty {
            var turnParams: [String: JSONValue] = [
                "threadId": .string(session.nativeSessionID),
                "input": .array([.object(["type": .string("text"), "text": .string(prompt)])]),
            ]
            if let effort = request.model?.reasoningOptionID {
                turnParams["effort"] = .string(effort)
            }
            let turn = try await connectedTransport().request(
                method: "turn/start",
                params: .object(turnParams)
            )
            if let turnID = turn["turn"]?["id"]?.stringValue {
                activeTurnIDs[session.nativeSessionID] = turnID
            }
            session.state = .working
            session.updatedAt = Date()
        }
        return session
    }

    func resumeSession(id: String) async throws -> AgentSession {
        let nativeID = id.hasPrefix("codex:") ? String(id.dropFirst("codex:".count)) : id
        let result = try await connectedTransport().request(
            method: "thread/resume",
            params: .object(["threadId": .string(nativeID), "excludeTurns": .bool(true)])
        )
        guard let session = CodexAppServerCodec.session(fromThreadResponse: result) else {
            throw CodexAppServerError.invalidMessage
        }
        knownSessionIDs.insert(session.nativeSessionID)
        return session
    }

    func loadConversation(sessionID: String) async throws -> [AgentConversationMessage] {
        let nativeID = normalizedNativeID(sessionID)
        let result = try await connectedTransport().request(
            method: "thread/read",
            params: .object([
                "threadId": .string(nativeID),
                "includeTurns": .bool(true),
            ])
        )
        return await Task.detached(priority: .userInitiated) {
            Self.conversationMessages(from: result)
        }.value
    }

    func sendPrompt(sessionID: String, prompt: String, model: ModelSelection?) async throws {
        let nativeID = normalizedNativeID(sessionID)
        var params: [String: JSONValue] = [
            "threadId": .string(nativeID),
            "input": .array([.object(["type": .string("text"), "text": .string(prompt)])]),
        ]
        if let modelID = model?.modelID { params["model"] = .string(modelID) }
        if let effort = model?.reasoningOptionID { params["effort"] = .string(effort) }
        let turn = try await connectedTransport().request(
            method: "turn/start",
            params: .object(params)
        )
        if let turnID = turn["turn"]?["id"]?.stringValue {
            activeTurnIDs[nativeID] = turnID
        }
    }

    func interrupt(sessionID: String) async throws {
        let nativeID = sessionID.hasPrefix("codex:")
            ? String(sessionID.dropFirst("codex:".count))
            : sessionID
        var turnID = activeTurnIDs[nativeID]
        if turnID == nil {
            let resumed = try await connectedTransport().request(
                method: "thread/resume",
                params: .object(["threadId": .string(nativeID)])
            )
            turnID = resumed["thread"]?["turns"]?.arrayValue?
                .last(where: { $0["status"]?.stringValue == "inProgress" })?["id"]?.stringValue
            if let turnID { activeTurnIDs[nativeID] = turnID }
        }
        guard let turnID else {
            throw CodexAppServerError.server(code: nil, message: "No active turn for this session")
        }
        _ = try await connectedTransport().request(
            method: "turn/interrupt",
            params: .object(["threadId": .string(nativeID), "turnId": .string(turnID)])
        )
    }

    func resolveApproval(
        sessionID: String,
        requestID: String,
        decision: ApprovalDecision
    ) async throws {
        let id: JSONValue = Double(requestID).map(JSONValue.number) ?? .string(requestID)
        let nativeDecision: String = switch decision {
        case .allow: "accept"
        case .allowForSession: "acceptForSession"
        case .deny: "decline"
        }
        try await connectedTransport().respond(
            id: id,
            result: .object(["decision": .string(nativeDecision)])
        )
    }

    func respondToUserInput(
        sessionID: String,
        requestID: String,
        answers: [String: [String]]
    ) async throws {
        let id: JSONValue = Double(requestID).map(JSONValue.number) ?? .string(requestID)
        let nativeAnswers = answers.mapValues { values in
            JSONValue.object(["answers": .array(values.map(JSONValue.string))])
        }
        try await connectedTransport().respond(
            id: id,
            result: .object(["answers": .object(nativeAnswers)])
        )
    }

    private func connectedTransport() throws -> CodexAppServerTransport {
        guard let transport else { throw CodexAppServerError.notConnected }
        return transport
    }

    private func normalizedNativeID(_ id: String) -> String {
        id.hasPrefix("codex:") ? String(id.dropFirst("codex:".count)) : id
    }

    nonisolated static func conversationMessages(from response: JSONValue) -> [AgentConversationMessage] {
        let turns = response["thread"]?["turns"]?.arrayValue ?? []
        return turns.flatMap { turn -> [AgentConversationMessage] in
            let timestamp = turn["startedAt"]?.numberValue.map(Date.init(timeIntervalSince1970:))
            return (turn["items"]?.arrayValue ?? []).compactMap { item in
                guard let id = item["id"]?.stringValue,
                      let type = item["type"]?.stringValue else { return nil }
                switch type {
                case "userMessage":
                    let text = item["content"]?.arrayValue?
                        .compactMap { $0["text"]?.stringValue }
                        .joined(separator: "\n") ?? ""
                    guard !text.isEmpty else { return nil }
                    return AgentConversationMessage(id: id, role: .user, content: text, createdAt: timestamp)
                case "agentMessage":
                    guard let text = item["text"]?.stringValue, !text.isEmpty else { return nil }
                    return AgentConversationMessage(id: id, role: .assistant, content: text, createdAt: timestamp)
                default:
                    return nil
                }
            }
        }
    }

    private func establishConnection(executableURL: URL) async throws {
        let newTransport = CodexAppServerTransport(executableURL: executableURL)
        try await newTransport.connect()
        transport = newTransport

        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await message in newTransport.messages {
                guard !Task.isCancelled else { return }
                self?.handle(message)
            }
        }

        statusTask?.cancel()
        statusTask = Task { [weak self] in
            for await status in newTransport.statuses {
                guard !Task.isCancelled else { return }
                await self?.handle(status, from: newTransport)
            }
        }
    }

    private func handle(
        _ status: CodexAppServerStatus,
        from failedTransport: CodexAppServerTransport
    ) async {
        guard !isDisconnecting, transport === failedTransport else { return }
        switch status {
        case .terminated:
            statusContinuation.yield(
                .disconnected(version: runtimeVersion, reason: "Codex app-server stopped; reconnecting")
            )
            await failedTransport.disconnect()
            transport = nil
            eventTask?.cancel()
            eventTask = nil
            statusTask?.cancel()
            statusTask = nil
            activeTurnIDs.removeAll()
            for sessionID in knownSessionIDs {
                yieldConnectionEvent(sessionID: sessionID, kind: .sessionEnded)
            }
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            let delays: [UInt64] = [500_000_000, 1_000_000_000, 2_000_000_000, 4_000_000_000, 8_000_000_000]
            for delay in delays {
                do {
                    try await Task.sleep(nanoseconds: delay)
                    guard !Task.isCancelled, !isDisconnecting else { return }
                    guard let executable = CodexExecutableLocator.locate() else { continue }
                    try await establishConnection(executableURL: executable)
                    let previouslyKnown = knownSessionIDs
                    let discovered = try await listSessions()
                    restoreDiscoveredSessions(discovered, limitedTo: previouslyKnown)
                    statusContinuation.yield(
                        .available(version: runtimeVersion)
                    )
                    reconnectTask = nil
                    return
                } catch is CancellationError {
                    return
                } catch {
                    continue
                }
            }
            statusContinuation.yield(
                .disconnected(version: runtimeVersion, reason: "Codex app-server reconnect failed")
            )
            reconnectTask = nil
        }
    }

    private func restoreDiscoveredSessions(
        _ sessions: [AgentSession],
        limitedTo sessionIDs: Set<String>
    ) {
        for session in sessions where sessionIDs.contains(session.nativeSessionID) {
            var metadata: [String: JSONValue] = [:]
            if let workspace = session.workspace { metadata["cwd"] = .string(workspace.path) }
            yieldConnectionEvent(
                sessionID: session.nativeSessionID,
                kind: .sessionResumed,
                metadata: metadata
            )
            switch session.state {
            case .idle:
                yieldConnectionEvent(sessionID: session.nativeSessionID, kind: .activityCompleted)
            case .failed:
                yieldConnectionEvent(sessionID: session.nativeSessionID, kind: .error)
            case .cancelled:
                yieldConnectionEvent(sessionID: session.nativeSessionID, kind: .cancelled)
            default:
                break
            }
        }
    }

    private func yieldConnectionEvent(
        sessionID: String,
        kind: AgentEventKind,
        metadata: [String: JSONValue] = [:]
    ) {
        eventSequence &+= 1
        eventContinuation.yield(
            AgentEvent(
                id: UUID(),
                sequence: eventSequence,
                runtime: .codex,
                provider: .openAI,
                sessionID: sessionID,
                timestamp: Date(),
                kind: kind,
                title: nil,
                detail: nil,
                tool: nil,
                approval: nil,
                userInput: nil,
                metadata: metadata
            )
        )
    }

    private func handle(_ message: JSONValue) {
        if let method = message["method"]?.stringValue,
           let params = message["params"] {
            let threadID = params["threadId"]?.stringValue
                ?? params["thread"]?["id"]?.stringValue
            if method == "turn/started", let threadID,
               let turnID = params["turn"]?["id"]?.stringValue {
                activeTurnIDs[threadID] = turnID
            } else if method == "turn/completed", let threadID {
                activeTurnIDs.removeValue(forKey: threadID)
            }
        }

        guard let native = CodexAppServerCodec.foundationMessage(from: message),
              let event = translatedEvent(native) else {
            return
        }
        knownSessionIDs.insert(event.sessionID)
        eventContinuation.yield(event)
    }

    private func translatedEvent(_ message: [String: Any]) -> AgentEvent? {
        eventSequence &+= 1
        return CodexAppServerEventTranslator.translate(message, sequence: eventSequence)
    }
}
