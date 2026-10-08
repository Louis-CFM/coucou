import Foundation

/// OpenRouter's catalogue and billing guard, shared by Settings and the chat picker.
/// Foundation-only so catalogue filtering and HTTP failures can be tested offline.
enum OpenRouterChat {
    enum Failure: LocalizedError {
        case unauthorized, rateLimited, http(Int), invalidCatalogue, unavailableModel

        var errorDescription: String? {
            switch self {
            case .unauthorized: "OpenRouter rejected the API key. Update it in Settings → Chat."
            case .rateLimited: "OpenRouter's free usage limit was reached or the provider is busy. Try again later."
            case .http(let status): "OpenRouter returned HTTP \(status). Try again later."
            case .invalidCatalogue: "OpenRouter's model list could not be read. Try refreshing it."
            case .unavailableModel: "This model is no longer available for free. Choose another OpenRouter model."
            }
        }
    }

    // Enforce zero token/request pricing at routing time as well as in the catalogue.
    // No model fallback list or paid tools/plugins are requested.
    static var freeProviderPreferences: [String: Any] {
        ["max_price": ["prompt": 0, "completion": 0, "request": 0]]
    }

    static func checkResponse(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: return
        case 401, 403: throw Failure.unauthorized
        case 429: throw Failure.rateLimited
        default: throw Failure.http(status)
        }
    }

    static func fetchModels(apiKey: String, session: URLSession = .shared) async throws -> [(id: String, label: String)] {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try checkResponse(response)
        return try parseModels(data)
    }

    static func parseModels(_ data: Data) throws -> [(id: String, label: String)] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { throw Failure.invalidCatalogue }
        var seen: Set<String> = []
        let models: [(id: String, label: String)] = items.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty,
                  let pricing = item["pricing"] as? [String: Any],
                  isZero(pricing["prompt"]), isZero(pricing["completion"]),
                  // Reject nonzero, unknown or dynamic charges rather than guessing.
                  pricing.values.allSatisfy({ isZero($0) }),
                  let architecture = item["architecture"] as? [String: Any],
                  let inputs = architecture["input_modalities"] as? [String], inputs.contains("text"),
                  let outputs = architecture["output_modalities"] as? [String], outputs.contains("text"),
                  seen.insert(id).inserted else { return nil }
            let name = item["name"] as? String ?? id
            return (id, id == "openrouter/free" ? "Auto — Free" : name)
        }
        return models.sorted {
            if $0.id == "openrouter/free" { return $1.id != "openrouter/free" }
            if $1.id == "openrouter/free" { return false }
            return $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
    }

    private static func isZero(_ value: Any?) -> Bool {
        guard let text = value as? String,
              let finite = Double(text), finite.isFinite,
              let number = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { return false }
        return number == 0
    }
}
