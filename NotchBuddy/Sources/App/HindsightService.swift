import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct BulkMutationFailure: Codable, Equatable {
    var id: String
    var kind: MemoryErrorKind
    var message: String
}

struct BulkMutationResult: Codable, Equatable {
    var requested: Int
    var succeeded: [String]
    var failed: [BulkMutationFailure]
    var refresh: Bool
}

struct MemoryListOptions {
    var filter = MemoryFilter()
    var documentId: String? = nil
    var tags: [String] = []
    var limit = 100
    var offset = 0
}

struct MemoryBrowseRequest: Codable, Equatable {
    var filter = MemoryFilter()
    var limit = 100
    var offset = 0
}

enum MemoryUpdateResult: Equatable {
    case updated(memory: MemoryRecord, refresh: Bool)
    case conflict(current: MemoryRecord)
}

struct MemoryMutationResult: Equatable {
    var memory: MemoryRecord
    var refresh: Bool
}

struct HindsightRetainInput {
    var documentId: String
    var items: [[String: JSONValue]]

    func validated() throws -> HindsightRetainInput? {
        documentId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

struct HindsightServiceError: Error, Equatable, CustomStringConvertible, LocalizedError {
    var kind: MemoryErrorKind
    var message: String
    var description: String { message }
    var errorDescription: String? { message }
}

protocol HindsightTransport: Sendable {
    func send(_ request: URLRequest, maximumBytes: Int, headerTimeout: TimeInterval) async throws -> (Data, URLResponse)
}

final class BoundedURLSessionTransport: NSObject, HindsightTransport, URLSessionDataDelegate, @unchecked Sendable {
    private final class Pending {
        var data = Data()
        var response: URLResponse?
        var watchdog: Task<Void, Never>?
        let maximumBytes: Int
        let continuation: CheckedContinuation<(Data, URLResponse), Error>

        init(maximumBytes: Int, continuation: CheckedContinuation<(Data, URLResponse), Error>) {
            self.maximumBytes = maximumBytes
            self.continuation = continuation
        }
    }

    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private lazy var session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)

    init(configuration: URLSessionConfiguration = HindsightService.connectionConfiguration()) {
        self.configuration = configuration
    }

    func send(_ request: URLRequest, maximumBytes: Int, headerTimeout: TimeInterval) async throws -> (Data, URLResponse) {
        let holder = CancellableTaskHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                let state = Pending(maximumBytes: maximumBytes, continuation: continuation)
                lock.withLock { pending[task.taskIdentifier] = state }
                holder.install(task)
                state.watchdog = Task { [weak self, weak task] in
                    try? await Task.sleep(nanoseconds: UInt64(headerTimeout * 1_000_000_000))
                    guard !Task.isCancelled, let self, let task else { return }
                    let timedOut = self.lock.withLock { self.pending.removeValue(forKey: task.taskIdentifier) }
                    if let timedOut {
                        task.cancel()
                        timedOut.continuation.resume(throwing: URLError(.timedOut))
                    }
                }
                task.resume()
            }
        } onCancel: {
            holder.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.withLock {
            pending[dataTask.taskIdentifier]?.response = response
            pending[dataTask.taskIdentifier]?.watchdog?.cancel()
            pending[dataTask.taskIdentifier]?.watchdog = nil
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var overflow: Pending?
        lock.withLock {
            guard let state = pending[dataTask.taskIdentifier] else { return }
            if state.data.count + data.count > state.maximumBytes {
                overflow = pending.removeValue(forKey: dataTask.taskIdentifier)
            } else {
                state.data.append(data)
            }
        }
        if let overflow {
            dataTask.cancel()
            overflow.continuation.resume(throwing: HindsightServiceError(kind: .invalidResponse, message: "Hindsight response exceeded the configured size limit"))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let state = lock.withLock({ pending.removeValue(forKey: task.taskIdentifier) }) else { return }
        state.watchdog?.cancel()
        if let error { state.continuation.resume(throwing: error); return }
        guard let response = state.response else {
            state.continuation.resume(throwing: HindsightServiceError(kind: .invalidResponse, message: "Hindsight returned an invalid response"))
            return
        }
        state.continuation.resume(returning: (state.data, response))
    }
}

private final class CancellableTaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func install(_ task: URLSessionTask) {
        let cancelNow = lock.withLock { self.task = task; return cancelled }
        if cancelNow { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock { cancelled = true; return self.task }
        task?.cancel()
    }
}

final class HindsightService: @unchecked Sendable {
    static let maxResponseBytes = 4 * 1024 * 1024
    private static let sessionLock = NSLock()
    private static var sharedAutomaticAuthenticationSuppressed = false
    static func clearAutomaticAuthenticationSuppression() { sessionLock.withLock { sharedAutomaticAuthenticationSuppressed = false } }
    static let maxBulkPages = 10_000

    private let config: HindsightConfig
    private var token: String
    private let transport: HindsightTransport
    private let headerTimeout: TimeInterval
    private let maxBulkPages: Int
    private let lock = NSLock()
    private var listGeneration: UInt64 = 0

    static func connectionConfiguration() -> URLSessionConfiguration {
        URLSessionConfiguration.ephemeral
    }

    init(config: HindsightConfig, transport: HindsightTransport = BoundedURLSessionTransport(), headerTimeout: TimeInterval = 5, maxBulkPages: Int = HindsightService.maxBulkPages) throws {
        guard let token = KeychainStore.shared.get(hindsightBearerTokenKey), !token.isEmpty else {
            throw HindsightServiceError(kind: .unauthorized, message: "Hindsight credential is missing")
        }
        try self.init(config: config, token: token, transport: transport, headerTimeout: headerTimeout, maxBulkPages: maxBulkPages)
    }

    init(config: HindsightConfig, token: String, transport: HindsightTransport = BoundedURLSessionTransport(), headerTimeout: TimeInterval = 5, maxBulkPages: Int = HindsightService.maxBulkPages) throws {
        try validateHindsightConfig(config)
        self.config = config
        self.token = token
        self.transport = transport
        self.headerTimeout = headerTimeout
        self.maxBulkPages = maxBulkPages
    }

    func replaceCredential(_ token: String) {
        lock.withLock { self.token = token }
        Self.clearAutomaticAuthenticationSuppression()
    }

    func isAutomaticAuthenticationSuppressed() -> Bool {
        Self.sessionLock.withLock { Self.sharedAutomaticAuthenticationSuppressed }
    }

    func testConnection() async throws {
        var components = URLComponents(url: try hindsightURL(config: config, suffix: ["memories", "list"]), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "limit", value: "0"), .init(name: "offset", value: "0")]
        let _: WireMemoryPage = try await send(try request(url: components.url!, method: "GET", timeout: 10))
        Self.clearAutomaticAuthenticationSuppression()
    }

    func recall(query: String, budget: Int, maxTokens: Int, automatic: Bool = false) async throws -> JSONValue {
        try checkSuppression(automatic)
        let body = try JSONSerialization.data(withJSONObject: ["query": query, "budget": budget, "max_tokens": maxTokens])
        let result: JSONValue = try await send(try request(url: hindsightURL(config: config, suffix: ["memories", "recall"]), method: "POST", timeout: 12, body: body), automatic: automatic)
        if !automatic { Self.clearAutomaticAuthenticationSuppression() }
        return result
    }

    func retain(_ input: HindsightRetainInput, automatic: Bool = false) async throws -> JSONValue {
        try checkSuppression(automatic)
        guard let input = try input.validated() else { throw failure(.invalidConfiguration, "Retain document_id must not be empty") }
        let items = input.items.map { item -> [String: JSONValue] in
            var wire = item
            wire["document_id"] = .string(input.documentId)
            return wire
        }
        let body = try JSONEncoder().encode(RetainPayload(items: items, async: false))
        let result: JSONValue = try await send(try request(url: hindsightURL(config: config, suffix: ["memories"]), method: "POST", timeout: 90, body: body), automatic: automatic)
        if !automatic { Self.clearAutomaticAuthenticationSuppression() }
        return result
    }

    func listMemories(options: MemoryListOptions = MemoryListOptions()) async throws -> MemoryPage {
        var components = URLComponents(url: try hindsightURL(config: config, suffix: ["memories", "list"]), resolvingAgainstBaseURL: false)!
        var query: [URLQueryItem] = []
        if let value = options.filter.query { query.append(.init(name: "q", value: value)) }
        if let value = options.filter.factType { query.append(.init(name: "type", value: value.rawValue)) }
        query.append(.init(name: "state", value: options.filter.state.rawValue))
        if let value = options.documentId { query.append(.init(name: "document_id", value: value)) }
        query.append(contentsOf: options.tags.map { .init(name: "tags", value: $0) })
        if !options.tags.isEmpty { query.append(.init(name: "tags_match", value: "all")) }
        if let value = options.filter.startDate { query.append(.init(name: "start_date", value: value)) }
        if let value = options.filter.endDate { query.append(.init(name: "end_date", value: value)) }
        if let value = options.filter.timeField { query.append(.init(name: "time_field", value: value.rawValue)) }
        query.append(.init(name: "limit", value: String(options.limit)))
        query.append(.init(name: "offset", value: String(options.offset)))
        components.queryItems = query
        let page: WireMemoryPage = try await send(try request(url: components.url!, method: "GET", timeout: 10))
        return page.publicValue
    }

    func listMemories(documentId: String, limit: Int = 100, offset: Int = 0) async throws -> MemoryPage {
        try await listMemories(options: MemoryListOptions(documentId: documentId, limit: limit, offset: offset))
    }

    func memoryList(_ request: MemoryBrowseRequest) async throws -> MemoryPage {
        let generation = lock.withLock { listGeneration &+= 1; return listGeneration }
        let page = try await listMemories(options: MemoryListOptions(
            filter: request.filter,
            documentId: request.filter.documentId,
            tags: strictTags(for: request.filter),
            limit: request.limit,
            offset: request.offset
        ))
        guard lock.withLock({ generation == listGeneration }) else {
            throw failure(.cancelled, "Hindsight list request was superseded")
        }
        return page
    }

    func memoryGet(id: String) async throws -> MemoryRecord { try await getMemory(id: id) }
    func memorySafeDetail(id: String, contentLimit: Int = 16_384) async throws -> SafeMemoryDetail { SafeMemoryDetail(record: try await getMemory(id: id), tenant: config.tenant, bank: config.bank, contentLimit: contentLimit) }

    func memoryUpdate(id: String, opened: MemoryRecord, update: MemoryUpdate, overwrite: Bool) async throws -> MemoryUpdateResult {
        guard opened.factType != .observation else { throw failure(.invalidConfiguration, "Observation memories cannot be edited") }
        let current = try await getMemory(id: id)
        guard current.factType != .observation else { throw failure(.invalidConfiguration, "Observation memories cannot be edited") }
        if current != opened && !overwrite { return .conflict(current: current) }
        return .updated(memory: try await updateMemory(id: id, update: update), refresh: true)
    }

    func memoryRetire(id: String) async throws -> MemoryMutationResult {
        .init(memory: try await updateMemory(id: id, update: MemoryUpdate(state: .invalidated, reason: "Retired from Coucou")), refresh: true)
    }

    func memoryRetire(confirmed: ConfirmedMemoryRetirement) async throws -> MemoryMutationResult {
        guard confirmed.endpoint == (try normalizedHindsightEndpoint(config)), confirmed.tenant == config.tenant, confirmed.bank == config.bank else {
            throw failure(.conflict, "Hindsight endpoint, tenant, or bank changed after confirmation")
        }
        let current = try await getMemory(id: confirmed.id)
        guard current.text == confirmed.text, current.updatedAt == confirmed.updatedAt else {
            throw failure(.conflict, "Memory changed after confirmation; review it again before retiring")
        }
        return try await memoryRetire(id: confirmed.id)
    }

    func memoryRestore(id: String) async throws -> MemoryMutationResult {
        .init(memory: try await restoreMemory(id: id), refresh: true)
    }

    func memoryBulkRetire(_ request: MemoryBrowseRequest) async throws -> BulkMutationResult {
        try await bulkRetire(options: MemoryListOptions(filter: request.filter, tags: strictTags(for: request.filter), limit: request.limit, offset: 0))
    }

    private func strictTags(for filter: MemoryFilter) -> [String] {
        var tags: [String] = []
        if let platform = filter.platform { tags.append("coucou:platform:\(platform.rawValue)") }
        if let retention = filter.retentionKind { tags.append("coucou:retention:\(retention.rawValue)") }
        if let source = filter.sourceKind { tags.append("coucou:source:\(source.rawValue)") }
        return tags
    }

    func getMemory(id: String) async throws -> MemoryRecord {
        let record: WireMemoryRecord = try await send(try request(url: hindsightURL(config: config, suffix: ["memories", id]), method: "GET", timeout: 10))
        return record.publicValue
    }

    func updateMemory(id: String, update: MemoryUpdate) async throws -> MemoryRecord {
        let body = try JSONEncoder().encode(WireMemoryUpdate(update))
        let record: WireMemoryRecord = try await send(try request(url: hindsightURL(config: config, suffix: ["memories", id]), method: "PATCH", timeout: 10, body: body))
        return record.publicValue
    }

    func retireMemory(id: String) async throws -> MemoryRecord { try await updateMemory(id: id, update: MemoryUpdate(state: .invalidated, reason: "Retired from Coucou")) }
    func restoreMemory(id: String) async throws -> MemoryRecord { try await updateMemory(id: id, update: MemoryUpdate(state: .valid)) }

    func bulkRetire(options original: MemoryListOptions) async throws -> BulkMutationResult {
        var options = original
        options.filter.state = .valid
        let pageSize = options.limit > 0 ? options.limit : 100
        var offset = 0
        var ids: [String] = []
        var seen = Set<String>()
        for pageNumber in 0...maxBulkPages {
            if pageNumber == maxBulkPages { throw failure(.invalidResponse, "Hindsight bulk pagination exceeded the maximum page count") }
            options.limit = pageSize
            options.offset = offset
            let page = try await listMemories(options: options)
            for record in page.items where seen.insert(record.id).inserted { ids.append(record.id) }
            if page.items.isEmpty || page.items.count < pageSize { break }
            let (next, overflow) = page.offset.addingReportingOverflow(page.items.count)
            if overflow { throw failure(.invalidResponse, "Hindsight bulk pagination offset overflowed") }
            if next <= offset { throw failure(.invalidResponse, "Hindsight bulk pagination did not advance") }
            offset = next
        }
        var succeeded: [String] = []
        var failed: [BulkMutationFailure] = []
        for start in stride(from: 0, to: ids.count, by: 4) {
            let batch = Array(ids[start..<min(start + 4, ids.count)])
            await withTaskGroup(of: (String, Result<MemoryRecord, Error>).self) { group in
                for id in batch { group.addTask { do { return (id, .success(try await self.retireMemory(id: id))) } catch { return (id, .failure(error)) } } }
                for await (id, result) in group {
                    switch result {
                    case .success: succeeded.append(id)
                    case .failure(let error):
                        let typed = error as? HindsightServiceError
                        failed.append(.init(id: id, kind: typed?.kind ?? .network, message: typed?.message ?? "Hindsight operation failed"))
                    }
                }
            }
        }
        let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        succeeded.sort { order[$0, default: .max] < order[$1, default: .max] }
        failed.sort { order[$0.id, default: .max] < order[$1.id, default: .max] }
        return .init(requested: ids.count, succeeded: succeeded, failed: failed, refresh: true)
    }

    func makeRequestForTesting(url: URL, method: String, timeout: TimeInterval, body: Data? = nil) throws -> URLRequest { try request(url: url, method: method, timeout: timeout, body: body) }
    func decodeMemoryForTesting(_ data: Data) throws -> MemoryRecord { try JSONDecoder().decode(WireMemoryRecord.self, from: data).publicValue }
    func encodeUpdateForTesting(_ update: MemoryUpdate) throws -> Data { try JSONEncoder().encode(WireMemoryUpdate(update)) }
    func connectionConfigurationForTesting() -> URLSessionConfiguration { Self.connectionConfiguration() }

    private func request(url: URL, method: String, timeout: TimeInterval, body: Data? = nil) throws -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(lock.withLock { token })", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    private func checkSuppression(_ automatic: Bool) throws {
        if automatic && isAutomaticAuthenticationSuppressed() { throw failure(.unauthorized, "Automatic Hindsight operations are suppressed") }
    }

    private func send<T: Decodable>(_ request: URLRequest, automatic: Bool = false) async throws -> T {
        do {
            let (data, response) = try await transport.send(request, maximumBytes: Self.maxResponseBytes, headerTimeout: headerTimeout)
            guard let http = response as? HTTPURLResponse else { throw failure(.invalidResponse, "Hindsight returned an invalid response") }
            guard (200..<300).contains(http.statusCode) else {
                let error = failure(kind(for: http.statusCode), "Hindsight request failed with status \(http.statusCode)")
                if automatic && http.statusCode == 401 { Self.sessionLock.withLock { Self.sharedAutomaticAuthenticationSuppressed = true } }
                throw error
            }
            do { return try JSONDecoder().decode(T.self, from: data) }
            catch { throw failure(.invalidResponse, "Hindsight returned malformed JSON") }
        } catch let error as HindsightServiceError { throw error }
        catch is CancellationError { throw failure(.cancelled, "Hindsight request was cancelled") }
        catch let error as URLError where error.code == .cancelled { throw failure(.cancelled, "Hindsight request was cancelled") }
        catch let error as URLError where error.code == .timedOut { throw failure(.timeout, "Hindsight request timed out") }
        catch let error as URLError where [.secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired].contains(error.code) { throw failure(.tls, "Hindsight TLS request failed") }
        catch let error as URLError where [.cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet].contains(error.code) { throw failure(.connection, "Hindsight connection failed") }
        catch { throw failure(.connection, "Hindsight network request failed") }
    }

    private func kind(for status: Int) -> MemoryErrorKind {
        switch status { case 401: return .unauthorized; case 403: return .forbidden; case 404: return .notFound; case 409: return .conflict; case 429: return .rateLimited; case 500...599: return .unavailable; default: return .invalidResponse }
    }

    private func failure(_ kind: MemoryErrorKind, _ message: String) -> HindsightServiceError { .init(kind: kind, message: message) }
}

private struct RetainPayload: Encodable { var items: [[String: JSONValue]]; var `async`: Bool }

private struct WireMemoryRecord: Decodable {
    var id: String; var text: String; var factType: MemoryFactType; var state: MemoryState = .valid
    var context: String?; var metadata: [String: JSONValue] = [:]; var tags: [String] = []; var entities: [String] = []
    var documentId: String?; var chunkId: String?; var createdAt: String?; var updatedAt: String?; var mentionedAt: String?
    var occurredStart: String?; var occurredEnd: String?; var editedAt: String?; var sourceFactIds: [String] = []
    enum CodingKeys: String, CodingKey { case id, text, factType = "fact_type", state, context, metadata, tags, entities, documentId = "document_id", chunkId = "chunk_id", createdAt = "created_at", updatedAt = "updated_at", mentionedAt = "mentioned_at", occurredStart = "occurred_start", occurredEnd = "occurred_end", editedAt = "edited_at", sourceFactIds = "source_fact_ids" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); text = try c.decode(String.self, forKey: .text); factType = try c.decode(MemoryFactType.self, forKey: .factType)
        state = try c.decodeIfPresent(MemoryState.self, forKey: .state) ?? .valid; context = try c.decodeIfPresent(String.self, forKey: .context)
        metadata = try c.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]; tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        entities = try c.decodeIfPresent([String].self, forKey: .entities) ?? []; documentId = try c.decodeIfPresent(String.self, forKey: .documentId)
        chunkId = try c.decodeIfPresent(String.self, forKey: .chunkId); createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt); updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        mentionedAt = try c.decodeIfPresent(String.self, forKey: .mentionedAt); occurredStart = try c.decodeIfPresent(String.self, forKey: .occurredStart); occurredEnd = try c.decodeIfPresent(String.self, forKey: .occurredEnd)
        editedAt = try c.decodeIfPresent(String.self, forKey: .editedAt); sourceFactIds = try c.decodeIfPresent([String].self, forKey: .sourceFactIds) ?? []
    }
    var publicValue: MemoryRecord { .init(id: id, text: text, factType: factType, state: state, context: context, metadata: metadata, tags: tags, entities: entities, documentId: documentId, chunkId: chunkId, createdAt: createdAt, updatedAt: updatedAt, mentionedAt: mentionedAt, occurredStart: occurredStart, occurredEnd: occurredEnd, editedAt: editedAt, sourceFactIds: sourceFactIds) }
}

private struct WireMemoryPage: Decodable {
    var items: [WireMemoryRecord]; var total: Int; var limit: Int; var offset: Int
    enum CodingKeys: String, CodingKey { case items, total, limit, offset }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([WireMemoryRecord].self, forKey: .items) ?? []
        total = try container.decode(Int.self, forKey: .total)
        limit = try container.decode(Int.self, forKey: .limit)
        offset = try container.decode(Int.self, forKey: .offset)
    }
    var publicValue: MemoryPage { .init(items: items.map(\.publicValue), total: total, limit: limit, offset: offset) }
}

private struct WireMemoryUpdate: Encodable {
    var text: String?; var context: String?; var occurredStart: String?; var occurredEnd: String?; var factType: MemoryFactType?
    var entities: [String]?; var resolveEntities: Bool; var state: MemoryState?; var reason: String?; var expectedUpdatedAt: String?
    init(_ value: MemoryUpdate) { text = value.text; context = value.context; occurredStart = value.occurredStart; occurredEnd = value.occurredEnd; factType = value.factType; entities = value.entities; resolveEntities = value.resolveEntities; state = value.state; reason = value.reason; expectedUpdatedAt = value.expectedUpdatedAt }
    enum CodingKeys: String, CodingKey { case text, context, occurredStart = "occurred_start", occurredEnd = "occurred_end", factType = "fact_type", entities, resolveEntities = "resolve_entities", state, reason, expectedUpdatedAt = "expected_updated_at" }
}

func validateHindsightLiveTestBank(_ bank: String) throws {
    guard bank.lowercased() != "hieu" else { throw HindsightServiceError(kind: .invalidConfiguration, message: "Live Hindsight mutation tests refuse bank hieu") }
}
