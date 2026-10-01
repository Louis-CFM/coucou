import Foundation

enum OpenAIProviderError: LocalizedError {
    case authenticationRequired
    case invalidAttachment(String)
    case invalidResponse
    case requestFailed(status: Int)

    var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            "OpenAI API key missing. Open settings to configure it."
        case .invalidAttachment(let name):
            "The attachment \(name) could not be read"
        case .invalidResponse:
            "OpenAI returned an unexpected response"
        case .requestFailed(let status):
            "OpenAI request failed with HTTP \(status)"
        }
    }
}

final class OpenAIProvider: AIProvider, @unchecked Sendable {
    static let defaultModelID = "gpt-5.6-luna"

    let id: ProviderID = .openAI
    let capabilities = ProviderCapabilities(
        dynamicModelCatalog: true,
        apiKeyAuthentication: true,
        accountAuthentication: false,
        streaming: false,
        toolCalling: true,
        webSearch: true,
        attachments: true
    )

    private let responsesEndpoint: URL
    private let modelsEndpoint: URL
    private let session: URLSession
    private let apiKey: @Sendable () -> String?
    private let cacheLock = NSLock()
    private var cachedModels: [ModelDescriptor]?

    init(
        responsesEndpoint: URL = URL(string: "https://api.openai.com/v1/responses")!,
        modelsEndpoint: URL = URL(string: "https://api.openai.com/v1/models")!,
        session: URLSession = .shared,
        apiKey: @escaping @Sendable () -> String? = {
            KeychainStore.shared.get("openai-api-key")
        }
    ) {
        self.responsesEndpoint = responsesEndpoint
        self.modelsEndpoint = modelsEndpoint
        self.session = session
        self.apiKey = apiKey
    }

    func authenticationStatus() async -> AuthenticationStatus {
        guard let key = apiKey(), !key.isEmpty else { return .notConfigured }
        return .connected(label: "API key")
    }

    func listModels(forceRefresh: Bool) async throws -> [ModelDescriptor] {
        if !forceRefresh, let cached = cacheLock.withLock({ cachedModels }) {
            return cached
        }
        guard let key = apiKey(), !key.isEmpty else {
            return Self.fallbackModels
        }

        var request = URLRequest(url: modelsEndpoint)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw OpenAIProviderError.requestFailed(
                    status: (response as? HTTPURLResponse)?.statusCode ?? 0
                )
            }
            let models = try Self.decodeModels(data)
            guard !models.isEmpty else { return Self.fallbackModels }
            cacheLock.withLock { cachedModels = models }
            return models
        } catch {
            if let cached = cacheLock.withLock({ cachedModels }) { return cached }
            return Self.fallbackModels
        }
    }

    func chat(_ request: ChatRequest) async throws -> ChatResponse {
        guard let key = apiKey(), !key.isEmpty else {
            throw OpenAIProviderError.authenticationRequired
        }

        var urlRequest = URLRequest(url: responsesEndpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBody(for: request))
        urlRequest.timeoutInterval = 45

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OpenAIProviderError.requestFailed(
                status: (response as? HTTPURLResponse)?.statusCode ?? 0
            )
        }
        return try Self.decodeResponse(data)
    }

    func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<ChatDelta, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let response = try await chat(request)
                    continuation.yield(
                        ChatDelta(text: response.message.content, metadata: response.metadata)
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    static let fallbackModels: [ModelDescriptor] = [
        descriptor(id: defaultModelID, catalogSource: "compatibility-fallback"),
    ]

    static func decodeModels(_ data: Data) throws -> [ModelDescriptor] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["data"] as? [[String: Any]] else {
            throw OpenAIProviderError.invalidResponse
        }
        return entries
            .compactMap { $0["id"] as? String }
            .filter(isChatModel)
            .map { descriptor(id: $0, catalogSource: "provider-api") }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    static func decodeResponse(_ data: Data) throws -> ChatResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = json["output"] as? [[String: Any]] else {
            throw OpenAIProviderError.invalidResponse
        }
        let text = output
            .filter { $0["type"] as? String == "message" }
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .filter { $0["type"] as? String == "output_text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw OpenAIProviderError.invalidResponse }

        var metadata: [String: JSONValue] = [:]
        if let responseID = json["id"] as? String { metadata["responseID"] = .string(responseID) }
        if let usage = json["usage"] as? [String: Any] {
            if let input = usage["input_tokens"] as? NSNumber {
                metadata["inputTokens"] = .number(input.doubleValue)
            }
            if let output = usage["output_tokens"] as? NSNumber {
                metadata["outputTokens"] = .number(output.doubleValue)
            }
        }

        return ChatResponse(
            message: AIChatMessage(id: UUID(), role: .assistant, content: text),
            finishReason: json["status"] as? String,
            metadata: metadata
        )
    }

    private func requestBody(for request: ChatRequest) throws -> [String: Any] {
        let firstUserIndex = request.messages.firstIndex(where: { $0.role == .user })
        let input: [[String: Any]] = try request.messages.enumerated().map { index, message in
            var content: [[String: Any]] = []
            if index == firstUserIndex {
                content.append(contentsOf: try request.attachments.map(attachmentBlock))
            }
            content.append([
                "type": message.role == .assistant ? "output_text" : "input_text",
                "text": message.content,
            ])
            return [
                "role": message.role == .assistant ? "assistant" : "user",
                "content": content,
            ]
        }

        var body: [String: Any] = [
            "model": request.modelID,
            "input": input,
            "store": false,
        ]
        if let prompt = request.systemPrompt, !prompt.isEmpty { body["instructions"] = prompt }
        if let maxTokens = request.maxOutputTokens { body["max_output_tokens"] = maxTokens }
        if let reasoning = request.reasoning {
            body["reasoning"] = ["effort": reasoning.providerValue]
        }
        if request.webSearch { body["tools"] = [["type": "web_search"]] }
        return body
    }

    private func attachmentBlock(_ attachment: ChatAttachment) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: attachment.location) else {
            throw OpenAIProviderError.invalidAttachment(attachment.name)
        }
        if attachment.mediaType.lowercased().hasPrefix("image/") {
            return [
                "type": "input_image",
                "image_url": "data:\(attachment.mediaType);base64,\(data.base64EncodedString())",
            ]
        }
        if attachment.mediaType.lowercased() == "application/pdf" {
            return [
                "type": "input_file",
                "filename": attachment.name,
                "file_data": "data:application/pdf;base64,\(data.base64EncodedString())",
            ]
        }
        guard data.count <= 200_000, let text = String(data: data, encoding: .utf8) else {
            throw OpenAIProviderError.invalidAttachment(attachment.name)
        }
        return ["type": "input_text", "text": "File contents:\n\(text)"]
    }

    private static func descriptor(id: String, catalogSource: String) -> ModelDescriptor {
        let reasoning = reasoningOptions(for: id)
        return ModelDescriptor(
            id: id,
            provider: .openAI,
            displayName: id,
            capabilities: ModelCapabilities(
                text: true,
                vision: true,
                attachments: true,
                toolCalling: true,
                webSearch: true,
                reasoning: !reasoning.isEmpty,
                streaming: false
            ),
            reasoningOptions: reasoning,
            contextWindow: nil,
            maxOutputTokens: nil,
            isDeprecated: false,
            metadata: ["catalogSource": catalogSource]
        )
    }

    private static func reasoningOptions(for id: String) -> [ReasoningOption] {
        let lower = id.lowercased()
        guard lower.hasPrefix("gpt-5") || lower.hasPrefix("o1") ||
                lower.hasPrefix("o3") || lower.hasPrefix("o4") else { return [] }
        return ["low", "medium", "high"].map {
            ReasoningOption(id: $0, displayName: $0.capitalized, providerValue: $0)
        }
    }

    private static func isChatModel(_ id: String) -> Bool {
        let lower = id.lowercased()
        guard lower.hasPrefix("gpt-") || lower.hasPrefix("o1") ||
                lower.hasPrefix("o3") || lower.hasPrefix("o4") else { return false }
        let excluded = [
            "audio", "realtime", "transcribe", "tts", "image", "search-preview",
            "embedding", "moderation", "chatgpt", "codex",
        ]
        return !excluded.contains(where: lower.contains)
    }
}
