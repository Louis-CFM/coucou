import Foundation

enum GeminiProviderError: LocalizedError {
    case authenticationRequired
    case invalidAttachment(String)
    case invalidModel(String)
    case invalidResponse
    case requestFailed(status: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            "Google Gemini API key missing. Open settings to configure it."
        case .invalidAttachment(let name):
            "The attachment \(name) could not be read"
        case .invalidModel(let model):
            "The Gemini model identifier \(model) is invalid"
        case .invalidResponse:
            "Gemini returned an unexpected response"
        case .requestFailed(let status, let message):
            message.map { "Gemini request failed with HTTP \(status): \($0)" }
                ?? "Gemini request failed with HTTP \(status)"
        }
    }
}

final class GeminiProvider: AIProvider, @unchecked Sendable {
    let id: ProviderID = .google
    let capabilities = ProviderCapabilities(
        dynamicModelCatalog: true,
        apiKeyAuthentication: true,
        accountAuthentication: false,
        streaming: false,
        toolCalling: true,
        webSearch: true,
        attachments: true
    )

    private let baseURL: URL
    private let session: URLSession
    private let apiKey: @Sendable () -> String?
    private let cacheLock = NSLock()
    private var cachedModels: [ModelDescriptor]?

    init(
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
        session: URLSession = .shared,
        apiKey: @escaping @Sendable () -> String? = {
            KeychainStore.shared.get("google-api-key")
        }
    ) {
        self.baseURL = baseURL
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
        guard let key = apiKey(), !key.isEmpty else { return [] }

        var request = URLRequest(url: baseURL.appending(path: "models"))
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 20

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw Self.requestError(data: data, response: response)
            }
            let models = try Self.decodeModels(data)
            cacheLock.withLock { cachedModels = models }
            return models
        } catch {
            if let cached = cacheLock.withLock({ cachedModels }) { return cached }
            throw error
        }
    }

    func chat(_ request: ChatRequest) async throws -> ChatResponse {
        guard let key = apiKey(), !key.isEmpty else {
            throw GeminiProviderError.authenticationRequired
        }
        let model = Self.normalizedModelID(request.modelID)
        guard !model.isEmpty, !model.contains("/") else {
            throw GeminiProviderError.invalidModel(request.modelID)
        }

        let endpoint = baseURL
            .appending(path: "models")
            .appending(path: "\(model):generateContent")
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBody(for: request))
        urlRequest.timeoutInterval = 60

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Self.requestError(data: data, response: response)
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

    static func decodeModels(_ data: Data) throws -> [ModelDescriptor] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["models"] as? [[String: Any]] else {
            throw GeminiProviderError.invalidResponse
        }
        return entries.compactMap { entry in
            guard let rawName = entry["name"] as? String else { return nil }
            let methods = entry["supportedGenerationMethods"] as? [String] ?? []
            guard methods.contains("generateContent") else { return nil }
            let modelID = normalizedModelID(rawName)
            guard modelID.lowercased().hasPrefix("gemini-") else { return nil }
            return descriptor(
                id: modelID,
                displayName: entry["displayName"] as? String ?? modelID,
                inputTokenLimit: (entry["inputTokenLimit"] as? NSNumber)?.intValue,
                outputTokenLimit: (entry["outputTokenLimit"] as? NSNumber)?.intValue
            )
        }
        .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    static func decodeResponse(_ data: Data) throws -> ChatResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]] else {
            throw GeminiProviderError.invalidResponse
        }
        let text = candidates.compactMap { candidate -> String? in
            guard let content = candidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else { return nil }
            return parts
                .filter { ($0["thought"] as? Bool) != true }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw GeminiProviderError.invalidResponse }

        var metadata: [String: JSONValue] = [:]
        if let responseID = json["responseId"] as? String {
            metadata["responseID"] = .string(responseID)
        }
        if let modelVersion = json["modelVersion"] as? String {
            metadata["modelVersion"] = .string(modelVersion)
        }
        if let usage = json["usageMetadata"] as? [String: Any] {
            for (source, target) in [
                ("promptTokenCount", "inputTokens"),
                ("candidatesTokenCount", "outputTokens"),
                ("thoughtsTokenCount", "thinkingTokens"),
            ] {
                if let count = usage[source] as? NSNumber {
                    metadata[target] = .number(count.doubleValue)
                }
            }
        }
        let finishReason = candidates.first?["finishReason"] as? String
        return ChatResponse(
            message: AIChatMessage(id: UUID(), role: .assistant, content: text),
            finishReason: finishReason,
            metadata: metadata
        )
    }

    func requestBody(for request: ChatRequest) throws -> [String: Any] {
        let firstUserIndex = request.messages.firstIndex(where: { $0.role == .user })
        let contents: [[String: Any]] = try request.messages.enumerated().map { index, message in
            var parts: [[String: Any]] = []
            if index == firstUserIndex {
                parts.append(contentsOf: try request.attachments.map(attachmentPart))
            }
            parts.append(["text": message.content])
            return [
                "role": message.role == .assistant ? "model" : "user",
                "parts": parts,
            ]
        }

        var body: [String: Any] = ["contents": contents]
        if let systemPrompt = request.systemPrompt, !systemPrompt.isEmpty {
            body["systemInstruction"] = ["parts": [["text": systemPrompt]]]
        }

        var generationConfig: [String: Any] = [:]
        if let maxTokens = request.maxOutputTokens {
            generationConfig["maxOutputTokens"] = maxTokens
        }
        if let reasoning = request.reasoning {
            let components = reasoning.providerValue.split(separator: ":", maxSplits: 1)
            if components.count == 2, components[0] == "level" {
                generationConfig["thinkingConfig"] = ["thinkingLevel": String(components[1])]
            } else if components.count == 2, components[0] == "budget",
                      let budget = Int(components[1]) {
                generationConfig["thinkingConfig"] = ["thinkingBudget": budget]
            }
        }
        if !generationConfig.isEmpty { body["generationConfig"] = generationConfig }

        var tools: [[String: Any]] = []
        if request.webSearch { tools.append(["google_search": [:]]) }
        if !request.tools.isEmpty {
            tools.append([
                "functionDeclarations": request.tools.map { tool in
                    [
                        "name": tool.id,
                        "description": tool.description,
                        "parameters": tool.inputSchema.foundationValue,
                    ]
                },
            ])
        }
        if !tools.isEmpty { body["tools"] = tools }
        return body
    }

    private func attachmentPart(_ attachment: ChatAttachment) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: attachment.location), data.count <= 20_000_000 else {
            throw GeminiProviderError.invalidAttachment(attachment.name)
        }
        return [
            "inlineData": [
                "mimeType": attachment.mediaType,
                "data": data.base64EncodedString(),
                "displayName": attachment.name,
            ],
        ]
    }

    private static func descriptor(
        id: String,
        displayName: String,
        inputTokenLimit: Int?,
        outputTokenLimit: Int?
    ) -> ModelDescriptor {
        let reasoning = reasoningOptions(for: id)
        return ModelDescriptor(
            id: id,
            provider: .google,
            displayName: displayName,
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
            contextWindow: inputTokenLimit,
            maxOutputTokens: outputTokenLimit,
            isDeprecated: false,
            metadata: ["catalogSource": "provider-api"]
        )
    }

    private static func reasoningOptions(for modelID: String) -> [ReasoningOption] {
        let lower = modelID.lowercased()
        if lower.hasPrefix("gemini-3") {
            return ["low", "medium", "high"].map {
                ReasoningOption(id: $0, displayName: $0.capitalized, providerValue: "level:\($0)")
            }
        }
        if lower.hasPrefix("gemini-2.5") {
            var options = [
                ReasoningOption(id: "dynamic", displayName: "Dynamic", providerValue: "budget:-1"),
                ReasoningOption(id: "1024", displayName: "1K tokens", providerValue: "budget:1024"),
            ]
            if !lower.contains("pro") {
                options.insert(
                    ReasoningOption(id: "off", displayName: "Off", providerValue: "budget:0"),
                    at: 0
                )
            }
            return options
        }
        return []
    }

    private static func normalizedModelID(_ value: String) -> String {
        value.hasPrefix("models/") ? String(value.dropFirst("models/".count)) : value
    }

    private static func requestError(data: Data, response: URLResponse) -> GeminiProviderError {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            .flatMap { $0["error"] as? [String: Any] }?["message"] as? String
        return .requestFailed(status: status, message: message)
    }
}
