import Foundation

/// A chat provider the user added: any server that speaks the OpenAI chat API.
/// Persisted as JSON in UserDefaults; the API key lives in the Keychain (`keychainKey`).
struct CustomProvider: Codable, Identifiable, Equatable, Sendable {
    /// Stable slug, also the Keychain account suffix. Never changes after creation.
    let id: String
    var name: String
    /// API root with its version path and no trailing slash, e.g. `https://api.groq.com/openai/v1`.
    var baseURL: String
    var requiresKey: Bool
    var model: String
    var colorHex: String
    /// Set for a provider that chats through a command line (`CLIChatTools`) instead of a URL.
    /// Old saved lists have no such key and decode as nil.
    var cliTool: String? = nil

    var keychainKey: String { CustomProviders.keychainKey(forID: id) }
}

/// One entry of the bundled provider catalog (`Resources/providers.json`, from models.dev).
struct ProviderCatalogEntry: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let baseURL: String
    let keyEnv: String?
    let doc: String?
    let popular: Bool?
}

/// A local server the automatic scan looks for.
struct LocalServerCandidate: Equatable, Sendable {
    let name: String
    /// API root, e.g. `http://127.0.0.1:11434/v1`.
    let baseURL: String
    /// Built-in providers have their own connection setting; others become custom providers.
    let builtInID: String?
}

enum CustomProviders {

    static let keychainPrefix = "custom-ai-key-"

    static func keychainKey(forID id: String) -> String { keychainPrefix + id }

    /// Servers worth probing on this Mac. Ports are the defaults each app ships with.
    static let knownLocalServers: [LocalServerCandidate] = [
        .init(name: "Ollama",    baseURL: "http://127.0.0.1:11434/v1", builtInID: "ollama"),
        .init(name: "LM Studio", baseURL: "http://127.0.0.1:1234/v1",  builtInID: "lmstudio"),
        .init(name: "llama.cpp", baseURL: "http://127.0.0.1:8080/v1",  builtInID: nil),
        .init(name: "vLLM",      baseURL: "http://127.0.0.1:8000/v1",  builtInID: nil),
        .init(name: "Jan",       baseURL: "http://127.0.0.1:1337/v1",  builtInID: nil),
    ]

    private static let palette = ["#F472B6", "#38BDF8", "#FB923C", "#A78BFA", "#34D399", "#F87171", "#FBBF24", "#2DD4BF"]

    // MARK: URL

    /// Cleans what the user typed into an API root, or returns nil when it cannot be one.
    /// Keeps the version path (`/v1`, `/openai/v1`, `/api/paas/v4`…): it differs per provider.
    static func normaliseBaseURL(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: s),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = comps.host, !host.isEmpty,
              comps.user == nil, comps.password == nil,
              comps.query == nil, comps.fragment == nil else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        // People paste the full endpoint; the app appends these itself.
        for tail in ["/chat/completions", "/models"] where s.lowercased().hasSuffix(tail) {
            s = String(s.dropLast(tail.count))
        }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// An API key must not travel in clear text over the internet: plain `http` is accepted
    /// only for this Mac and the local network.
    static func isTransportAllowed(_ baseURL: String) -> Bool {
        guard let comps = URLComponents(string: baseURL), let scheme = comps.scheme?.lowercased(),
              let rawHost = comps.host?.lowercased() else { return false }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 127 || parts[0] == 10
            || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 172 && (16...31).contains(parts[1]))
    }

    // MARK: Identity

    /// `Groq` → `groq`, a second `Groq` → `groq-2`. Always non-empty and unique among `existing`.
    static func slug(from name: String, existing: [String]) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let dashed = folded.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? String($0) : "-" }.joined()
        let words = dashed.split(separator: "-").map(String.init)
        let base = words.isEmpty ? "provider" : words.joined(separator: "-")
        guard existing.contains(base) else { return base }
        var n = 2
        while existing.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    /// A stable colour per provider so the same one always looks the same.
    static func color(forID id: String) -> String {
        let sum = id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return palette[sum % palette.count]
    }

    // MARK: Models

    private static let excludedModelHints = ["embed", "bge-", "all-minilm", "clip", "rerank", "moderat",
                                             "whisper", "tts", "dall-e", "image", "audio", "realtime", "transcribe"]

    /// Reads an OpenAI-style `GET /models` reply (`{"data":[{"id":…}]}`) and drops non-chat models.
    /// Newest first when the server gives `created`, else the server's order.
    /// Returns nil when the reply is not a model list at all.
    static func parseModelList(_ data: Data) -> [(id: String, label: String)]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // Ollama with nothing downloaded answers {"object":"list","data":null}: an empty list.
        if json["object"] as? String == "list", json["data"] is NSNull { return [] }
        guard let items = json["data"] as? [[String: Any]] else { return nil }
        let models = items.compactMap { item -> (id: String, created: Int)? in
            guard let raw = item["id"] as? String, !raw.isEmpty else { return nil }
            let id = raw.hasPrefix("models/") ? String(raw.dropFirst(7)) : raw
            let lower = id.lowercased()
            guard !excludedModelHints.contains(where: { lower.contains($0) }) else { return nil }
            return (id, item["created"] as? Int ?? 0)
        }
        let hasDates = models.contains { $0.created > 0 }
        let ordered = hasDates ? models.sorted { $0.created > $1.created } : models
        return ordered.map { (id: $0.id, label: $0.id) }
    }

    // MARK: Auto-connect

    /// Which found tools and servers to connect now. A tool the user removed (`dismissed`) stays
    /// removed on the automatic scans; the Scan button passes `force` to bring everything back.
    /// `found` are matched to what is already connected by tool id, or by URL for a server.
    static func providersToConnect(found: [CustomProvider], connected: [CustomProvider],
                                   dismissed: Set<String>, force: Bool) -> [CustomProvider] {
        found.filter { candidate in
            let already = connected.contains {
                candidate.cliTool != nil ? $0.cliTool == candidate.cliTool : $0.baseURL == candidate.baseURL
            }
            return !already && (force || !dismissed.contains(autoConnectKey(for: candidate)))
        }
    }

    /// Whether to fill Ollama's or LM Studio's own URL field (`builtInID` of a scan candidate).
    static func shouldConnectBuiltIn(id: String, currentURL: String, dismissed: Set<String>, force: Bool) -> Bool {
        currentURL.isEmpty && (force || !dismissed.contains(id))
    }

    /// The name under which "I removed this" is remembered.
    static func autoConnectKey(for provider: CustomProvider) -> String {
        provider.cliTool.map { "cli:\($0)" } ?? "url:\(provider.baseURL)"
    }

    // MARK: Catalog + storage

    static func decodeCatalog(_ data: Data) -> [ProviderCatalogEntry] {
        struct File: Decodable { let providers: [ProviderCatalogEntry] }
        return (try? JSONDecoder().decode(File.self, from: data))?.providers ?? []
    }

    static func decodeProviders(_ data: Data?) -> [CustomProvider] {
        guard let data, let list = try? JSONDecoder().decode([CustomProvider].self, from: data) else { return [] }
        // A hand-edited or corrupt file must not put an unsafe endpoint in front of a key, or
        // run a command Coucou does not know.
        return list.filter {
            if let tool = $0.cliTool { return CLIChatTools.tool(id: tool) != nil && $0.baseURL.isEmpty }
            return normaliseBaseURL($0.baseURL) == $0.baseURL && isTransportAllowed($0.baseURL)
        }
    }

    static func encodeProviders(_ list: [CustomProvider]) -> Data? {
        try? JSONEncoder().encode(list)
    }

    /// Case-insensitive match on name, id and URL, for the catalog search field.
    static func search(_ catalog: [ProviderCatalogEntry], _ query: String) -> [ProviderCatalogEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return catalog }
        return catalog.filter {
            $0.name.lowercased().contains(q) || $0.id.contains(q) || $0.baseURL.lowercased().contains(q)
        }
    }
}
