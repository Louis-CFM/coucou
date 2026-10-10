import Foundation

/// Network side of custom chat providers: model lists, the Mac scan, the bundled catalog.
/// The pure rules (URL checks, parsing, storage) live in CoucouKit/CustomProviders.swift.
enum CustomProviderClient {

    enum FetchError: Error, Equatable {
        case unreachable
        case unauthorized
        /// The server answered, but not with an OpenAI-style model list.
        case notAModelList
    }

    /// Refuses redirects: a key must only ever reach the host the user typed.
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    private static let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)

    // MARK: Models

    /// `GET {baseURL}/models`. The key is sent only when there is one.
    static func fetchModels(baseURL: String, apiKey: String?, timeout: TimeInterval = 10)
        async -> Result<[(id: String, label: String)], FetchError> {
        guard CustomProviders.isTransportAllowed(baseURL),
              let url = URL(string: baseURL + "/models") else { return .failure(.unreachable) }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        if let apiKey, !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse else { return .failure(.unreachable) }
        if http.statusCode == 401 || http.statusCode == 403 { return .failure(.unauthorized) }
        guard http.statusCode == 200, let models = CustomProviders.parseModelList(data) else {
            return .failure(.notAModelList)
        }
        return .success(models)
    }

    // MARK: Scan this Mac (local servers)

    struct FoundServer: Sendable {
        let candidate: LocalServerCandidate
        let models: [String]
    }

    /// Asks each well-known local port whether it serves a model list. Runs at launch, when
    /// Settings → Chat opens and on Scan again; nothing leaves the machine (every URL is on 127.0.0.1).
    static func scanThisMac() async -> [FoundServer] {
        await withTaskGroup(of: FoundServer?.self) { group in
            for candidate in CustomProviders.knownLocalServers {
                group.addTask {
                    guard case .success(let models) = await fetchModels(baseURL: candidate.baseURL, apiKey: nil, timeout: 1.5)
                    else { return nil }
                    return FoundServer(candidate: candidate, models: models.map(\.id))
                }
            }
            var found: [FoundServer] = []
            for await server in group { if let server { found.append(server) } }
            let order = CustomProviders.knownLocalServers.map(\.baseURL)
            return found.sorted { (order.firstIndex(of: $0.candidate.baseURL) ?? 0) < (order.firstIndex(of: $1.candidate.baseURL) ?? 0) }
        }
    }

    // MARK: Catalog

    /// The provider list shipped inside the app: a snapshot of models.dev, never fetched at run time.
    static func loadCatalog() -> [ProviderCatalogEntry] {
        guard let url = Bundle.main.url(forResource: "providers", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return CustomProviders.decodeCatalog(data)
    }
}
