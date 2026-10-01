import Foundation

enum ProviderID: String, Codable, CaseIterable, Hashable, Sendable {
    case anthropic
    case openAI = "openai"
    case google
}

enum AgentRuntimeID: String, Codable, CaseIterable, Hashable, Sendable {
    case claudeCode = "claude-code"
    case codex
    case geminiCLI = "gemini-cli"
    case antigravity
}

enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

extension JSONValue {
    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var numberValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    var foundationValue: Any {
        switch self {
        case .string(let value): value
        case .number(let value): value
        case .bool(let value): value
        case .object(let value): value.mapValues(\.foundationValue)
        case .array(let value): value.map(\.foundationValue)
        case .null: NSNull()
        }
    }
}

struct ReasoningOption: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let displayName: String
    let providerValue: String
}

struct ModelCapabilities: Codable, Hashable, Sendable {
    let text: Bool
    let vision: Bool
    let attachments: Bool
    let toolCalling: Bool
    let webSearch: Bool
    let reasoning: Bool
    let streaming: Bool
}

struct ModelDescriptor: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let provider: ProviderID
    let displayName: String
    let capabilities: ModelCapabilities
    let reasoningOptions: [ReasoningOption]
    let contextWindow: Int?
    let maxOutputTokens: Int?
    let isDeprecated: Bool
    let metadata: [String: String]
}

struct ProviderCapabilities: Codable, Hashable, Sendable {
    let dynamicModelCatalog: Bool
    let apiKeyAuthentication: Bool
    let accountAuthentication: Bool
    let streaming: Bool
    let toolCalling: Bool
    let webSearch: Bool
    let attachments: Bool
}

struct AgentRuntimeCapabilities: Codable, Hashable, Sendable {
    let observeSessions: Bool
    let startSession: Bool
    let resumeSession: Bool
    let interrupt: Bool
    let approvals: Bool
    let userInputRequests: Bool
    let toolEvents: Bool
    let fileChanges: Bool
    let commandEvents: Bool
    let subagents: Bool
    let runtimeModelSelection: Bool
    let runtimeReasoningSelection: Bool
}

enum AgentSessionState: String, Codable, CaseIterable, Hashable, Sendable {
    case starting
    case idle
    case working
    case waitingForApproval
    case waitingForUser
    case completed
    case failed
    case cancelled
    case disconnected
}

enum AgentEventKind: Codable, Hashable, Sendable {
    case sessionStarted
    case sessionResumed
    case sessionEnded
    case userPrompt
    case activityStarted
    case activityUpdated
    case activityCompleted
    case toolStarted
    case toolCompleted
    case toolFailed
    case commandStarted
    case commandCompleted
    case commandFailed
    case fileChanged
    case approvalRequested
    case approvalResolved
    case userInputRequested
    case subagentStarted
    case subagentCompleted
    case rateLimited
    case warning
    case error
    case cancelled
    case completed
    case providerSpecific(name: String)
}

struct AgentToolInfo: Codable, Hashable, Sendable {
    let name: String
    let summary: String?
    let input: [String: JSONValue]
}

enum ApprovalDecision: String, Codable, Hashable, Sendable {
    case allow
    case allowForSession
    case deny
}

struct AgentApprovalRequest: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let detail: String?
    let tool: AgentToolInfo?
    let choices: [ApprovalDecision]
}

struct AgentUserInputOption: Codable, Hashable, Sendable {
    let label: String
    let description: String
}

struct AgentUserInputQuestion: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let header: String
    let question: String
    let options: [AgentUserInputOption]
    let allowsOther: Bool
    let isSecret: Bool
}

struct AgentUserInputRequest: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let itemID: String
    let questions: [AgentUserInputQuestion]
    let isBlocking: Bool
}

struct AgentEvent: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var sequence: UInt64? = nil
    let runtime: AgentRuntimeID
    let provider: ProviderID?
    let sessionID: String
    let timestamp: Date
    let kind: AgentEventKind
    let title: String?
    let detail: String?
    let tool: AgentToolInfo?
    let approval: AgentApprovalRequest?
    let userInput: AgentUserInputRequest?
    let metadata: [String: JSONValue]
}

struct ModelSelection: Codable, Hashable, Sendable {
    let modelID: String
    let reasoningOptionID: String?
}

struct AgentActivity: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let title: String
    let detail: String?
    let startedAt: Date
    var completedAt: Date?
}

struct AgentSession: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let runtime: AgentRuntimeID
    let provider: ProviderID?
    let nativeSessionID: String
    let workspace: URL?
    var state: AgentSessionState
    var model: ModelSelection?
    var latestActivity: AgentActivity?
    var pendingApproval: AgentApprovalRequest?
    var pendingUserInput: AgentUserInputRequest?
    let startedAt: Date
    var updatedAt: Date
    var metadata: [String: JSONValue]
}

struct AgentConversationMessage: Identifiable, Codable, Hashable, Sendable {
    enum Role: String, Codable, Hashable, Sendable {
        case user
        case assistant
        case system
    }

    let id: String
    let role: Role
    let content: String
    let createdAt: Date?
}

extension AgentSession {
    /// A human title for the conversation. Codex's preview is the actual chat subject;
    /// the working-directory name is only a fallback and must not masquerade as the title.
    var displayTitle: String {
        if let preview = metadata["preview"]?.stringValue {
            let titleSource: Substring
            if let requestMarker = preview.range(of: "## My request:", options: .caseInsensitive) {
                titleSource = preview[requestMarker.upperBound...]
            } else {
                titleSource = preview[...]
            }
            let collapsed = titleSource
                .split(whereSeparator: \Character.isWhitespace)
                .joined(separator: " ")
            if !collapsed.isEmpty {
                let limit = 52
                return collapsed.count > limit
                    ? String(collapsed.prefix(limit - 1)) + "…"
                    : collapsed
            }
        }
        return workspace?.lastPathComponent.nonEmptyTitle ?? runtime.displayName
    }
}

private extension String {
    var nonEmptyTitle: String? { isEmpty ? nil : self }
}

private extension AgentRuntimeID {
    var displayName: String {
        switch self {
        case .claudeCode: "Claude session"
        case .codex: "Codex session"
        case .geminiCLI: "Gemini session"
        case .antigravity: "Antigravity"
        }
    }
}

enum RuntimeAvailability: Codable, Hashable, Sendable {
    case available(version: String?)
    case disconnected(version: String?, reason: String?)
    case unavailable(reason: String?)
    case authenticationRequired(reason: String?)
    case unsupported(reason: String)
}

enum AgentRuntimeError: LocalizedError, Equatable {
    case runtimeNotRegistered
    case unknownSession
    case staleRequest
    case unsupportedFeature(String)

    var errorDescription: String? {
        switch self {
        case .runtimeNotRegistered:
            "Agent runtime is not registered"
        case .unknownSession:
            "Unknown agent session"
        case .staleRequest:
            "This agent request is no longer active"
        case .unsupportedFeature(let feature):
            "\(feature) is not supported by this runtime"
        }
    }
}

struct StartAgentSessionRequest: Codable, Hashable, Sendable {
    let workspace: URL?
    let prompt: String?
    let model: ModelSelection?
    let metadata: [String: JSONValue]
}

enum AuthenticationStatus: Codable, Hashable, Sendable {
    case notConfigured
    case connected(label: String?)
    case expired
    case error(message: String)
}

struct AIChatMessage: Identifiable, Codable, Hashable, Sendable {
    enum Role: String, Codable, Hashable, Sendable {
        case system
        case user
        case assistant
        case tool
    }

    let id: UUID
    let role: Role
    let content: String
}

struct ChatAttachment: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let name: String
    let mediaType: String
    let location: URL
}

struct ChatTool: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let description: String
    let inputSchema: JSONValue
}

struct ReasoningSelection: Codable, Hashable, Sendable {
    let optionID: String
    let providerValue: String
}

struct ChatRequest: Codable, Hashable, Sendable {
    let modelID: String
    let messages: [AIChatMessage]
    let systemPrompt: String?
    let reasoning: ReasoningSelection?
    let attachments: [ChatAttachment]
    let tools: [ChatTool]
    let webSearch: Bool
    let maxOutputTokens: Int?
}

struct ChatResponse: Codable, Hashable, Sendable {
    let message: AIChatMessage
    let finishReason: String?
    let metadata: [String: JSONValue]
}

struct ChatDelta: Codable, Hashable, Sendable {
    let text: String
    let metadata: [String: JSONValue]
}
