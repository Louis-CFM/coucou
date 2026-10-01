import Foundation

enum CodexAppServerCodec {
    static func models(from result: JSONValue) -> [ModelDescriptor] {
        result["data"]?.arrayValue?.compactMap { value in
            guard let model = value.objectValue,
                  model["hidden"] != .bool(true),
                  let id = model["model"]?.stringValue ?? model["id"]?.stringValue else {
                return nil
            }
            let modalities = Set(model["inputModalities"]?.arrayValue?.compactMap(\.stringValue) ?? ["text", "image"])
            let reasoning = model["supportedReasoningEfforts"]?.arrayValue?.compactMap { option -> ReasoningOption? in
                guard let value = option["reasoningEffort"]?.stringValue else { return nil }
                return ReasoningOption(
                    id: value,
                    displayName: value.capitalized,
                    providerValue: value
                )
            } ?? []
            return ModelDescriptor(
                id: id,
                provider: .openAI,
                displayName: model["displayName"]?.stringValue ?? id,
                capabilities: ModelCapabilities(
                    text: modalities.contains("text"),
                    vision: modalities.contains("image"),
                    attachments: modalities.contains("image"),
                    toolCalling: true,
                    webSearch: true,
                    reasoning: !reasoning.isEmpty,
                    streaming: true
                ),
                reasoningOptions: reasoning,
                contextWindow: nil,
                maxOutputTokens: nil,
                isDeprecated: model["upgrade"]?.stringValue != nil,
                metadata: [
                    "defaultReasoningEffort": model["defaultReasoningEffort"]?.stringValue ?? "",
                ]
            )
        } ?? []
    }

    static func sessions(from result: JSONValue) -> [AgentSession] {
        result["data"]?.arrayValue?.compactMap { session(fromThread: $0) } ?? []
    }

    static func session(fromThreadResponse result: JSONValue) -> AgentSession? {
        guard let thread = result["thread"] else { return nil }
        return session(fromThread: thread)
    }

    static func session(fromThread value: JSONValue) -> AgentSession? {
        guard let thread = value.objectValue,
              let id = thread["id"]?.stringValue else {
            return nil
        }

        let createdAt = date(seconds: thread["createdAt"]) ?? Date()
        let updatedAt = date(seconds: thread["updatedAt"]) ?? createdAt
        let modelID = thread["model"]?.stringValue
        let reasoning = thread["reasoningEffort"]?.stringValue
        let workspace = thread["cwd"]?.stringValue.map(URL.init(fileURLWithPath:))
        return AgentSession(
            id: "codex:\(id)",
            runtime: .codex,
            provider: .openAI,
            nativeSessionID: id,
            workspace: workspace,
            state: state(from: thread["status"]),
            model: modelID.map { ModelSelection(modelID: $0, reasoningOptionID: reasoning) },
            latestActivity: nil,
            pendingApproval: nil,
            pendingUserInput: nil,
            startedAt: createdAt,
            updatedAt: updatedAt,
            metadata: [
                "preview": thread["preview"] ?? .string(""),
                "modelProvider": thread["modelProvider"] ?? .string("openai"),
            ]
        )
    }

    static func foundationMessage(from value: JSONValue) -> [String: Any]? {
        value.foundationValue as? [String: Any]
    }

    private static func date(seconds value: JSONValue?) -> Date? {
        value?.numberValue.map(Date.init(timeIntervalSince1970:))
    }

    private static func state(from value: JSONValue?) -> AgentSessionState {
        let status = value?.stringValue ?? value?["type"]?.stringValue
        return switch status {
        case "active": .working
        case "idle": .idle
        case "systemError": .failed
        case "notLoaded": .disconnected
        default: .idle
        }
    }
}
