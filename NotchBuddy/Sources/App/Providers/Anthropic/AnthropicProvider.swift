import Foundation

enum AnthropicProviderError: LocalizedError {
    case authenticationRequired
    case invalidAttachment(String)
    case invalidResponse
    case requestFailed(status: Int)

    var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            "Anthropic API key missing. Open settings to configure it."
        case .invalidAttachment(let name):
            "The attachment \(name) could not be read"
        case .invalidResponse:
            "Anthropic returned an unexpected response"
        case .requestFailed(let status):
            "Anthropic request failed with HTTP \(status)"
        }
    }
}

final class AnthropicProvider: AIProvider, @unchecked Sendable {
    static let defaultModelID = "claude-sonnet-4-6"

    let id: ProviderID = .anthropic
    let capabilities = ProviderCapabilities(
        dynamicModelCatalog: false,
        apiKeyAuthentication: true,
        accountAuthentication: false,
        streaming: false,
        toolCalling: true,
        webSearch: true,
        attachments: true
    )

    private let endpoint: URL
    private let session: URLSession
    private let apiKey: @Sendable () -> String?
    private let anthropicVersion = "2023-06-01"

    init(
        endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
        session: URLSession = .shared,
        apiKey: @escaping @Sendable () -> String? = {
            KeychainStore.shared.get("anthropic-api-key")
        }
    ) {
        self.endpoint = endpoint
        self.session = session
        self.apiKey = apiKey
    }

    func authenticationStatus() async -> AuthenticationStatus {
        guard let key = apiKey(), !key.isEmpty else { return .notConfigured }
        return .connected(label: "API key")
    }

    func listModels(forceRefresh: Bool) async throws -> [ModelDescriptor] {
        Self.fallbackModels
    }

    func chat(_ request: ChatRequest) async throws -> ChatResponse {
        guard let key = apiKey(), !key.isEmpty else {
            throw AnthropicProviderError.authenticationRequired
        }

        let body = try requestBody(for: request)
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        if request.webSearch {
            urlRequest.setValue("web-search-2025-03-05", forHTTPHeaderField: "anthropic-beta")
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        urlRequest.timeoutInterval = 45

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AnthropicProviderError.requestFailed(status: status)
        }
        return try Self.decodeResponse(data)
    }

    func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<ChatDelta, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let response = try await chat(request)
                    continuation.yield(ChatDelta(text: response.message.content, metadata: response.metadata))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    static let fallbackModels: [ModelDescriptor] = [
        ModelDescriptor(
            id: defaultModelID,
            provider: .anthropic,
            displayName: "Claude Sonnet",
            capabilities: ModelCapabilities(
                text: true,
                vision: true,
                attachments: true,
                toolCalling: true,
                webSearch: true,
                reasoning: false,
                streaming: false
            ),
            reasoningOptions: [],
            contextWindow: nil,
            maxOutputTokens: 4096,
            isDeprecated: false,
            metadata: ["catalogSource": "compatibility-fallback"]
        ),
    ]

    static func decodeResponse(_ data: Data) throws -> ChatResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let textBlock = content.first(where: { $0["type"] as? String == "text" }),
              let text = textBlock["text"] as? String,
              !text.isEmpty else {
            throw AnthropicProviderError.invalidResponse
        }

        var metadata: [String: JSONValue] = [:]
        if let stopReason = json["stop_reason"] as? String {
            metadata["stopReason"] = .string(stopReason)
        }
        if let usage = json["usage"] as? [String: Any] {
            if let input = usage["input_tokens"] as? NSNumber {
                metadata["inputTokens"] = .number(input.doubleValue)
            }
            if let output = usage["output_tokens"] as? NSNumber {
                metadata["outputTokens"] = .number(output.doubleValue)
            }
        }

        return ChatResponse(
            message: AIChatMessage(
                id: UUID(),
                role: .assistant,
                content: text.trimmingCharacters(in: .whitespacesAndNewlines)
            ),
            finishReason: json["stop_reason"] as? String,
            metadata: metadata
        )
    }

    private func requestBody(for request: ChatRequest) throws -> [String: Any] {
        // Attachments belong to the original user context. Re-emitting them on that
        // turn preserves file context when a stateless API receives later turns.
        let firstUserIndex = request.messages.firstIndex(where: { $0.role == .user })
        let messages: [[String: Any]] = try request.messages.enumerated().map { index, message in
            var content: [[String: Any]] = []
            if index == firstUserIndex {
                content.append(contentsOf: try request.attachments.map(attachmentBlock))
            }
            content.append(["type": "text", "text": message.content])
            return [
                "role": message.role == .assistant ? "assistant" : "user",
                "content": content,
            ]
        }

        var body: [String: Any] = [
            "model": request.modelID,
            "max_tokens": request.maxOutputTokens ?? 4096,
            "messages": messages,
        ]
        if let systemPrompt = request.systemPrompt, !systemPrompt.isEmpty {
            body["system"] = systemPrompt
        }
        if request.webSearch {
            body["tools"] = [[
                "type": "web_search_20250305",
                "name": "web_search",
                "max_uses": 5,
            ]]
        }
        return body
    }

    private func attachmentBlock(_ attachment: ChatAttachment) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: attachment.location) else {
            throw AnthropicProviderError.invalidAttachment(attachment.name)
        }
        let mediaType = attachment.mediaType.lowercased()
        if mediaType == "application/pdf" {
            return base64Block(type: "document", mediaType: mediaType, data: data)
        }
        if mediaType.hasPrefix("image/") {
            return base64Block(type: "image", mediaType: mediaType, data: data)
        }
        guard data.count <= 200_000,
              let text = String(data: data, encoding: .utf8) else {
            throw AnthropicProviderError.invalidAttachment(attachment.name)
        }
        return ["type": "text", "text": "File contents:\n\(text)"]
    }

    private func base64Block(type: String, mediaType: String, data: Data) -> [String: Any] {
        [
            "type": type,
            "source": [
                "type": "base64",
                "media_type": mediaType,
                "data": data.base64EncodedString(),
            ],
        ]
    }
}
