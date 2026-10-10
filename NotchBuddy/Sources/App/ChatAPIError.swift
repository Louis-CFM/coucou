import Foundation

/// Do not expose raw HTML responses (proxies can return those instead of JSON).
struct ChatAPIError: LocalizedError {
    let status: Int
    let provider: String
    let model: String
    let detail: String?

    init(status: Int, provider: String, model: String, data: Data) {
        self.status = status
        self.provider = provider
        self.model = model
        let json = try? JSONSerialization.jsonObject(with: data)
        let object = (json as? [String: Any]) ?? (json as? [[String: Any]])?.first
        let error = object?["error"] as? [String: Any]
        let message = (error?["message"] as? String) ?? (object?["message"] as? String)
            ?? (object?["error"] as? String)
        detail = message.flatMap { $0.isEmpty ? nil : String($0.prefix(600)) }
    }

    var errorDescription: String? {
        let advice: String
        switch status {
        case 404: advice = "Model or endpoint not found, or this key has no access. Reopen Chat and choose an available model from the refreshed model menu."
        case 401, 403: advice = "Check this provider's API key and permissions in Settings → Chat."
        case 429: advice = "Rate or quota limit reached. Wait before retrying, or check your provider's quota."
        case 500...599: advice = "The provider is temporarily unavailable. Try again later."
        default: advice = "The provider rejected the request."
        }
        let heading = "\(provider) · \(model) (HTTP \(status))"
        return [heading, advice, detail].compactMap { $0 }.joined(separator: "\n\n")
    }
}
