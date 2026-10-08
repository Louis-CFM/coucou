import Foundation

// MARK: - Vertex AI (Google Cloud)
//
// When a Google Cloud project is set in Settings → Chat, the Anthropic and Google AI
// providers go through Vertex AI instead of their own APIs: Claude via
// `publishers/anthropic/models/<model>:rawPredict`, Gemini via the OpenAI-compatible
// `endpoints/openapi`. Auth uses the Application Default Credentials written by
// `gcloud auth application-default login` — no API key, nothing stored in the Keychain.

enum VertexAI {
    static let projectKey = "vertexProject"
    static let regionKey  = "vertexRegion"
    static let defaultRegion = "global"
    static let anthropicVersion = "vertex-2023-10-16"

    static var project: String {
        (UserDefaults.standard.string(forKey: projectKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var region: String {
        let r = (UserDefaults.standard.string(forKey: regionKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return r.isEmpty ? defaultRegion : r
    }

    /// Vertex is used as soon as a project is set and the ADC file exists.
    /// Off in the App Store build: the sandbox cannot read ~/.config/gcloud.
    #if APPSTORE
    static var isEnabled: Bool { false }
    #else
    static var isEnabled: Bool { !project.isEmpty && credentialsAvailable }
    #endif

    /// Providers that Vertex can serve.
    static func serves(_ provider: ChatProvider) -> Bool {
        isEnabled && (provider == .anthropic || provider == .google)
    }

    static var credentialsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/gcloud/application_default_credentials.json")
    }

    static var credentialsAvailable: Bool {
        FileManager.default.isReadableFile(atPath: credentialsURL.path)
    }

    // MARK: URLs

    private static var host: String {
        region == "global" ? "aiplatform.googleapis.com" : "\(region)-aiplatform.googleapis.com"
    }

    private static var locationBase: String {
        "https://\(host)/v1/projects/\(project)/locations/\(region)"
    }

    static func claudeURL(model: String) -> URL? {
        URL(string: "\(locationBase)/publishers/anthropic/models/\(model):rawPredict")
    }

    /// Base URL of the OpenAI-compatible endpoint (append "/chat/completions").
    static var openAIBaseURL: String { "\(locationBase)/endpoints/openapi" }

    /// The OpenAI-compatible endpoint wants Gemini models as "google/<id>".
    static func geminiModelId(_ model: String) -> String {
        model.hasPrefix("google/") ? model : "google/\(model)"
    }

    // MARK: Model lists

    /// Anthropic models published on Vertex, newest families first.
    /// The catalogue lists every model, including ones the project has not enabled.
    static func fetchClaudeModels() async -> [(id: String, label: String)] {
        let names = await fetchPublisherModels(publisher: "anthropic")
        return names
            .filter { $0.hasPrefix("claude-") }
            .sorted { $0.localizedStandardCompare($1) == .orderedDescending }
            .flatMap { id -> [(id: String, label: String)] in
                // Opus and Sonnet also come as a 1M-context variant ("[1m]", like Claude Code).
                guard id.contains("opus") || id.contains("sonnet") else { return [(id: id, label: id)] }
                return [(id: id + ClaudeService.longContextSuffix, label: id + " (1M)"), (id: id, label: id)]
            }
    }

    /// Gemini chat models published on Vertex.
    static func fetchGeminiModels() async -> [(id: String, label: String)] {
        let excluded = ["embed", "imagen", "veo", "aqa", "tts", "audio", "live", "image"]
        let names = await fetchPublisherModels(publisher: "google")
        return names
            .filter { name in
                let lower = name.lowercased()
                return lower.hasPrefix("gemini") && !excluded.contains(where: { lower.contains($0) })
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedDescending }
            .map { (id: $0, label: $0) }
    }

    private static func fetchPublisherModels(publisher: String) async -> [String] {
        guard let token = try? await VertexToken.shared.accessToken(),
              let url = URL(string: "https://aiplatform.googleapis.com/v1beta1/publishers/\(publisher)/models?pageSize=200")
        else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(project, forHTTPHeaderField: "x-goog-user-project")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["publisherModels"] as? [[String: Any]] else { return [] }
        // "publishers/anthropic/models/claude-opus-5-5" → "claude-opus-5-5"
        return items.compactMap { ($0["name"] as? String)?.components(separatedBy: "/").last }
    }

    /// Reads the error message out of a Vertex / Google API error body.
    static func errorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let first = (json as? [String: Any]) ?? (json as? [[String: Any]])?.first,
              let err = first["error"] as? [String: Any] else { return nil }
        return err["message"] as? String
    }
}

// MARK: - Access token from the Application Default Credentials

enum VertexAuthError: LocalizedError {
    case noCredentials
    case unsupportedCredentials(String)
    case refreshFailed(String)

    var errorDescription: String? {
        switch self {
        case .noCredentials:
            return "Google Cloud credentials missing. Run `gcloud auth application-default login`."
        case .unsupportedCredentials(let type):
            return "Unsupported Google Cloud credentials (\(type)). Run `gcloud auth application-default login`."
        case .refreshFailed(let msg):
            return "Google Cloud sign-in failed: \(msg). Run `gcloud auth application-default login`."
        }
    }
}

/// Exchanges the ADC refresh token for an access token and caches it until shortly before it expires.
actor VertexToken {
    static let shared = VertexToken()

    private var token: String?
    private var expiry = Date.distantPast

    func accessToken() async throws -> String {
        if let token, Date() < expiry { return token }

        guard let data = try? Data(contentsOf: VertexAI.credentialsURL),
              let creds = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VertexAuthError.noCredentials
        }
        let type = creds["type"] as? String ?? "unknown"
        guard type == "authorized_user",
              let clientId = creds["client_id"] as? String,
              let clientSecret = creds["client_secret"] as? String,
              let refreshToken = creds["refresh_token"] as? String else {
            throw VertexAuthError.unsupportedCredentials(type)
        }

        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            .init(name: "grant_type", value: "refresh_token"),
            .init(name: "client_id", value: clientId),
            .init(name: "client_secret", value: clientSecret),
            .init(name: "refresh_token", value: refreshToken),
        ]
        req.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        let (body, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let access = json["access_token"] as? String else {
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            let msg = json?["error_description"] as? String ?? json?["error"] as? String
                ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
            throw VertexAuthError.refreshFailed(msg)
        }
        let lifetime = json["expires_in"] as? Double ?? 3600
        token = access
        expiry = Date().addingTimeInterval(lifetime - 120)
        return access
    }
}

// MARK: - Provider readiness

extension ChatProvider {
    /// True when the chat can talk to this cloud provider: Vertex for Anthropic and Google,
    /// otherwise an API key in the Keychain. Local providers are checked by their server URL elsewhere.
    var hasCloudCredentials: Bool {
        if VertexAI.serves(self) { return true }
        return KeychainStore.shared.get(keychainKey) != nil
    }
}
