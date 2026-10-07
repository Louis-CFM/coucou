import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private actor ScriptedTransport: HindsightTransport {
    enum Step { case response(Int, Data), failure(Error) }
    private var steps: [Step]
    private(set) var requests: [URLRequest] = []
    private(set) var headerTimeouts: [TimeInterval] = []

    init(_ steps: [Step]) { self.steps = steps }

    func send(_ request: URLRequest, maximumBytes: Int, headerTimeout: TimeInterval) async throws -> (Data, URLResponse) {
        requests.append(request); headerTimeouts.append(headerTimeout)
        guard !steps.isEmpty else { throw URLError(.badServerResponse) }
        let step = steps.removeFirst()
        switch step {
        case .failure(let error): throw error
        case .response(let status, let data):
            guard data.count <= maximumBytes else { throw HindsightServiceError(kind: .invalidResponse, message: "Hindsight response exceeded the configured size limit") }
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
}

private actor RacingListTransport: HindsightTransport {
    func send(_ request: URLRequest, maximumBytes: Int, headerTimeout: TimeInterval) async throws -> (Data, URLResponse) {
        let old = request.url?.query?.contains("q=old") == true
        if old { try await Task.sleep(nanoseconds: 100_000_000) }
        let ids = old ? ["old"] : ["newest", "older"]
        let data = try memoryPage(ids, offset: 0, limit: 2)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private final class HindsightTestURLProtocol: URLProtocol {
    struct Plan {
        var status = 200
        var chunks: [Data] = []
        var error: Error? = nil
        var headerDelay: TimeInterval = 0
        var bodyDelay: TimeInterval = 0
    }
    private static let lock = NSLock()
    private static var plans: [Plan] = []
    private var stopped = false

    static func enqueue(_ plans: [Plan]) { lock.withLock { self.plans.append(contentsOf: plans) } }
    private static func dequeue() -> Plan { lock.withLock { plans.removeFirst() } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let plan = Self.dequeue()
        Task {
            if plan.headerDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(plan.headerDelay * 1_000_000_000)) }
            guard !stopped else { return }
            if let error = plan.error { client?.urlProtocol(self, didFailWithError: error); return }
            let response = HTTPURLResponse(url: request.url!, statusCode: plan.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if plan.bodyDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(plan.bodyDelay * 1_000_000_000)) }
            guard !stopped else { return }
            for chunk in plan.chunks { client?.urlProtocol(self, didLoad: chunk) }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() { stopped = true }
}

private func productionTransport() -> BoundedURLSessionTransport {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HindsightTestURLProtocol.self]
    return BoundedURLSessionTransport(configuration: configuration)
}

private func assertJSONObject(_ data: Data, equals expected: [String: Any]) throws {
    let actual = try JSONSerialization.jsonObject(with: data) as! NSDictionary
    precondition(actual == expected as NSDictionary, "JSON mismatch:\nactual: \(actual)\nexpected: \(expected)")
}

private func expectServiceError(_ expected: MemoryErrorKind, _ label: String, operation: () async throws -> Void) async {
    do {
        try await operation()
        preconditionFailure("\(label) did not throw")
    } catch let error as HindsightServiceError {
        precondition(error.kind == expected, "\(label) returned \(error.kind), expected \(expected)")
    } catch {
        preconditionFailure("\(label) returned untyped error \(error)")
    }
}

private final class TestKeychainBackend: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    var writeStatus: Int32
    var deleteStatus: Int32

    init(values: [String: String], writeStatus: Int32, deleteStatus: Int32) {
        self.values = values
        self.writeStatus = writeStatus
        self.deleteStatus = deleteStatus
    }

    func load(key: String) -> String? { lock.withLock { values[key] } }
    func save(key: String, value: String) -> Int32 {
        lock.withLock { if writeStatus == 0 { values[key] = value }; return writeStatus }
    }
    func delete(key: String) -> Int32 {
        lock.withLock { if deleteStatus == 0 || deleteStatus == KeychainStatus.itemNotFound { values[key] = nil }; return deleteStatus }
    }
}

private func memoryPage(_ ids: [String], offset: Int, limit: Int) throws -> Data {
    let items = ids.map { ["id": $0, "text": $0, "fact_type": "world"] }
    return try JSONSerialization.data(withJSONObject: ["items": items, "total": 0, "limit": limit, "offset": offset])
}

@main
enum HindsightContractTests {
    static func main() async throws {
        let config = HindsightConfig(
            enabled: true,
            baseUrl: "https://host.example/hindsight/",
            tenant: "default",
            bank: "hieu",
            automaticRecall: true,
            inferredRetention: true,
            allowDevelopmentHttp: false
        )
        precondition(try hindsightURL(config: config, suffix: ["memories", "recall"]).absoluteString ==
            "https://host.example/hindsight/v1/default/banks/hieu/memories/recall")
        var endpointCase = config
        endpointCase.baseUrl = "https://HOST.example:443/Hindsight/"
        precondition(try normalizedHindsightEndpoint(endpointCase) == "https://host.example/Hindsight")
        endpointCase.baseUrl = "https://host.example/hindsight"
        precondition(try normalizedHindsightEndpoint(endpointCase) != "https://host.example/Hindsight")

        for baseUrl in [
            "https://user@host.example/hindsight",
            "https://host.example/hindsight?query=1",
            "https://host.example/hindsight#fragment",
            "http://host.example/hindsight",
            "https:///hindsight",
            "https://:443/hindsight",
        ] {
            var unsafe = config
            unsafe.baseUrl = baseUrl
            precondition((try? validateHindsightConfig(unsafe)) == nil)
        }

        var development = config
        development.baseUrl = "http://localhost:8888/hindsight"
        development.allowDevelopmentHttp = true
        try validateHindsightConfig(development)

        for segment in ["a/b", "a\\b", "a%2fb", "a%2Fb", "a%5cb", "a%5Cb", "a\nb"] {
            var unsafe = config
            unsafe.tenant = segment
            precondition((try? validateHindsightConfig(unsafe)) == nil)
            unsafe.tenant = "default"
            unsafe.bank = segment
            precondition((try? validateHindsightConfig(unsafe)) == nil)
        }

        let enumCases: [(String, String)] = [
            (MemoryFactType.world.rawValue, "world"), (MemoryFactType.experience.rawValue, "experience"),
            (MemoryFactType.observation.rawValue, "observation"), (MemoryState.valid.rawValue, "valid"),
            (MemoryState.invalidated.rawValue, "invalidated"), (RetentionKind.explicit.rawValue, "explicit"),
            (RetentionKind.inferred.rawValue, "inferred"), (MemoryPlatform.windows.rawValue, "windows"),
            (MemoryPlatform.macos.rawValue, "macos"),
            (MemoryErrorKind.invalidConfiguration.rawValue, "invalidConfiguration"),
            (MemoryErrorKind.authenticationRequired.rawValue, "authenticationRequired"), (MemoryErrorKind.forbidden.rawValue, "forbidden"),
            (MemoryErrorKind.notFound.rawValue, "notFound"), (MemoryErrorKind.conflict.rawValue, "conflict"),
            (MemoryErrorKind.rateLimited.rawValue, "rateLimited"), (MemoryErrorKind.server.rawValue, "server"),
            (MemoryErrorKind.invalidResponse.rawValue, "invalidResponse"), (MemoryErrorKind.timeout.rawValue, "timeout"),
            (MemoryErrorKind.connection.rawValue, "connection"), (MemoryErrorKind.tls.rawValue, "tls"),
            (MemoryErrorKind.cancelled.rawValue, "cancelled"),
        ]
        for (actual, expected) in enumCases { precondition(actual == expected) }

        let record = MemoryRecord(
            id: "memory-1", text: "Remember this", factType: .experience, state: .invalidated,
            context: "context", metadata: ["platform": .string("windows")], tags: ["tag"], entities: ["Coucou"],
            documentId: "document-1", chunkId: "chunk-1", createdAt: "created", updatedAt: "updated",
            mentionedAt: "mentioned", occurredStart: "start", occurredEnd: "end", editedAt: "edited",
            sourceFactIds: ["source-1"]
        )
        let recordFixture: [String: Any] = [
            "id": "memory-1", "text": "Remember this", "factType": "experience", "state": "invalidated",
            "context": "context", "metadata": ["platform": "windows"], "tags": ["tag"], "entities": ["Coucou"],
            "documentId": "document-1", "chunkId": "chunk-1", "createdAt": "created", "updatedAt": "updated",
            "mentionedAt": "mentioned", "occurredStart": "start", "occurredEnd": "end", "editedAt": "edited",
            "sourceFactIds": ["source-1"],
        ]
        try assertJSONObject(JSONEncoder().encode(record), equals: recordFixture)
        try assertJSONObject(JSONEncoder().encode(MemoryPage(items: [record], total: 1, limit: 25, offset: 0)), equals: [
            "items": [recordFixture], "total": 1, "limit": 25, "offset": 0,
        ])

        let filter = MemoryFilter(
            query: "query", factType: .world, state: .invalidated, startDate: "start-date", endDate: "end-date",
            timeField: .mentionedAt, platform: .windows, retentionKind: .explicit, sourceKind: .chat
        )
        try assertJSONObject(JSONEncoder().encode(filter), equals: [
            "query": "query", "factType": "world", "state": "invalidated", "startDate": "start-date",
            "endDate": "end-date", "timeField": "mentioned_at", "platform": "windows",
            "retentionKind": "explicit", "sourceKind": "chat",
        ])

        let update = MemoryUpdate(
            text: "new text", context: "new context", occurredStart: "start", occurredEnd: "end",
            factType: .observation, entities: ["Coucou"], resolveEntities: true, state: .invalidated,
            reason: "duplicate", expectedUpdatedAt: "expected"
        )
        try assertJSONObject(JSONEncoder().encode(update), equals: [
            "text": "new text", "context": "new context", "occurredStart": "start", "occurredEnd": "end",
            "factType": "observation", "entities": ["Coucou"], "resolveEntities": true,
            "state": "invalidated", "reason": "duplicate", "expectedUpdatedAt": "expected",
        ])

        let minimalRecord = MemoryRecord(
            id: "memory-1", text: "text", factType: .world, state: .valid,
            metadata: [:], tags: [], entities: [], sourceFactIds: []
        )
        try assertJSONObject(JSONEncoder().encode(minimalRecord), equals: [
            "id": "memory-1", "text": "text", "factType": "world", "state": "valid",
            "metadata": [:], "tags": [], "entities": [], "sourceFactIds": [],
        ])

        precondition((try? JSONDecoder().decode(MemoryFilter.self, from: Data("{\"timeField\":\"invented\"}".utf8))) == nil)
        precondition((try? JSONDecoder().decode(MemoryFilter.self, from: Data("{\"sourceKind\":\"tool\"}".utf8))) == nil)
        let decodedFilter = try JSONDecoder().decode(MemoryFilter.self, from: Data("{}".utf8))
        precondition(decodedFilter == MemoryFilter())
        try assertJSONObject(JSONEncoder().encode(decodedFilter), equals: ["state": "valid"])
        let decodedUpdate = try JSONDecoder().decode(MemoryUpdate.self, from: Data("{}".utf8))
        precondition(decodedUpdate == MemoryUpdate())
        try assertJSONObject(JSONEncoder().encode(decodedUpdate), equals: ["resolveEntities": false])

        let service = try HindsightService(config: config, token: "test-secret")
        let connectionURL = try hindsightURL(config: config, suffix: ["memories", "list"])
            .appending(queryItems: [URLQueryItem(name: "limit", value: "0"), URLQueryItem(name: "offset", value: "0")])
        let connectionRequest = try service.makeRequestForTesting(url: connectionURL, method: "GET", timeout: 10)
        precondition(connectionRequest.url?.path.hasSuffix("/v1/default/banks/hieu/memories/list") == true)
        precondition(connectionRequest.url?.query == "limit=0&offset=0")
        precondition(connectionRequest.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret")
        precondition(connectionRequest.value(forHTTPHeaderField: "Accept") == "application/json")
        precondition(connectionRequest.timeoutInterval == 10)

        let recallBody = try JSONSerialization.data(withJSONObject: ["query": "where", "budget": 20, "max_tokens": 500])
        let recallRequest = try service.makeRequestForTesting(
            url: try hindsightURL(config: config, suffix: ["memories", "recall"]), method: "POST", timeout: 12, body: recallBody)
        try assertJSONObject(recallRequest.httpBody!, equals: ["query": "where", "budget": 20, "max_tokens": 500])
        precondition(recallRequest.timeoutInterval == 12)

        do {
            try validateHindsightLiveTestBank("hieu")
            preconditionFailure("production bank was accepted")
        } catch {}
        try validateHindsightLiveTestBank("disposable-test")

        let wireRecord = Data("""
        {"id":"memory-2","text":"wire","fact_type":"observation","state":"valid","document_id":"doc-2","chunk_id":"chunk-2","created_at":"created","updated_at":"updated","mentioned_at":"mentioned","occurred_start":"start","occurred_end":"end","edited_at":"edited","metadata":null,"tags":null,"entities":null,"source_fact_ids":null}
        """.utf8)
        let decodedWire = try service.decodeMemoryForTesting(wireRecord)
        precondition(decodedWire.factType == .observation && decodedWire.documentId == "doc-2")
        precondition(decodedWire.metadata.isEmpty && decodedWire.tags.isEmpty && decodedWire.entities.isEmpty && decodedWire.sourceFactIds.isEmpty)
        let wireUpdate = try service.encodeUpdateForTesting(MemoryUpdate(
            occurredStart: "start", factType: .observation, resolveEntities: true, expectedUpdatedAt: "expected"))
        try assertJSONObject(wireUpdate, equals: [
            "occurred_start": "start", "fact_type": "observation", "resolve_entities": true,
            "expected_updated_at": "expected",
        ])
        let publicUpdate = try JSONSerialization.jsonObject(with: JSONEncoder().encode(MemoryUpdate(occurredStart: "start"))) as! [String: Any]
        precondition(publicUpdate["occurredStart"] != nil && publicUpdate["occurred_start"] == nil)
        precondition(try HindsightRetainInput(documentId: "", items: []).validated() == nil)
        precondition(try HindsightRetainInput(documentId: "caller-unique", items: []).validated() != nil)
        precondition(service.connectionConfigurationForTesting().timeoutIntervalForResource != 5)

        let emptyPage = Data("{\"items\":null,\"total\":0,\"limit\":10,\"offset\":0}".utf8)
        let statusTransport = ScriptedTransport([.response(401, Data())])
        let statusService = try HindsightService(config: config, token: "secret", transport: statusTransport)
        do { try await statusService.testConnection(); preconditionFailure("401 accepted") }
        catch let error as HindsightServiceError { precondition(error.kind == .unauthorized) }

        let malformedService = try HindsightService(config: config, token: "secret", transport: ScriptedTransport([.response(200, Data("bad".utf8))]))
        do { try await malformedService.testConnection(); preconditionFailure("malformed JSON accepted") }
        catch let error as HindsightServiceError { precondition(error.kind == .invalidResponse) }

        let timeoutService = try HindsightService(config: config, token: "secret", transport: ScriptedTransport([.failure(URLError(.timedOut))]))
        do { try await timeoutService.testConnection(); preconditionFailure("timeout accepted") }
        catch let error as HindsightServiceError { precondition(error.kind == .timeout) }

        let cancelledService = try HindsightService(config: config, token: "secret", transport: ScriptedTransport([.failure(URLError(.cancelled))]))
        do { try await cancelledService.testConnection(); preconditionFailure("cancellation accepted") }
        catch let error as HindsightServiceError { precondition(error.kind == .cancelled) }

        let suppressionTransport = ScriptedTransport([.response(401, Data()), .response(200, Data("{}".utf8))])
        let suppressionService = try HindsightService(config: config, token: "old", transport: suppressionTransport)
        do { _ = try await suppressionService.recall(query: "q", budget: 1, maxTokens: 1, automatic: true) }
        catch {}
        precondition(suppressionService.isAutomaticAuthenticationSuppressed())
        suppressionService.replaceCredential("new")
        precondition(!suppressionService.isAutomaticAuthenticationSuppressed())
        _ = try await suppressionService.recall(query: "q", budget: 1, maxTokens: 1)

        let pageService = try HindsightService(config: config, token: "secret", transport: ScriptedTransport([.response(200, emptyPage)]))
        precondition(try await pageService.listMemories().items.isEmpty)

        let safeRecord = MemoryRecord(id: "safe", text: String(repeating: "x", count: 20), factType: .world, state: .valid, context: String(repeating: "y", count: 20), metadata: ["coucou.turnId": .string("turn"), "unknown": .string("<script>")], tags: ["tag"], entities: ["entity"], documentId: "doc", chunkId: "chunk", createdAt: "created", updatedAt: "updated", sourceFactIds: ["source"])
        let safeDetail = SafeMemoryDetail(record: safeRecord, tenant: "tenant", bank: "bank", contentLimit: 8)
        precondition(safeDetail.content == "xxxxxxxx" && safeDetail.context == "yyyyyyyy")
        precondition(safeDetail.metadata == ["coucou.turnId": "turn"])
        precondition(safeDetail.documentId == "doc" && safeDetail.chunkId == "chunk" && safeDetail.sourceFactIds == ["source"])
        let hostileDetail = SafeMemoryDetail(record: MemoryRecord(
            id: String(repeating: "i", count: 2_000), text: "safe", factType: .world, state: .valid,
            metadata: ["coucou.turnId": .string(String(repeating: "m", count: 2_000))],
            tags: Array(repeating: String(repeating: "t", count: 1_000), count: 1_000),
            entities: Array(repeating: String(repeating: "e", count: 1_000), count: 1_000),
            documentId: String(repeating: "d", count: 2_000), chunkId: String(repeating: "c", count: 2_000),
            createdAt: String(repeating: "1", count: 2_000), updatedAt: String(repeating: "2", count: 2_000), mentionedAt: String(repeating: "3", count: 2_000),
            occurredStart: String(repeating: "4", count: 2_000), occurredEnd: String(repeating: "5", count: 2_000), editedAt: String(repeating: "6", count: 2_000),
            sourceFactIds: Array(repeating: String(repeating: "s", count: 1_000), count: 1_000)
        ), tenant: "tenant", bank: "bank")
        precondition(hostileDetail.tags.count <= safeMemoryCollectionLimit && hostileDetail.entities.count <= safeMemoryCollectionLimit && hostileDetail.sourceFactIds.count <= safeMemoryCollectionLimit)
        precondition(hostileDetail.tags.allSatisfy { $0.count <= safeMemoryValueLimit } && hostileDetail.metadata.values.allSatisfy { $0.count <= safeMemoryValueLimit })
        precondition(hostileDetail.id.count <= safeMemoryIdentifierLimit && (hostileDetail.documentId?.count ?? 0) <= safeMemoryIdentifierLimit && (hostileDetail.chunkId?.count ?? 0) <= safeMemoryIdentifierLimit)
        precondition([hostileDetail.createdAt, hostileDetail.updatedAt, hostileDetail.mentionedAt, hostileDetail.occurredStart, hostileDetail.occurredEnd, hostileDetail.editedAt].allSatisfy { ($0?.count ?? 0) <= safeMemoryValueLimit })

        precondition(!HindsightConfig.defaults.enabled, "legacy defaults must not opt into memory")
        precondition(!AppSessionDefaults.privateChat, "private chat must start off and remain session-only")
        let lifecycle = memoryManagerWindowConfiguration()
        precondition(lifecycle.isSingleton && lifecycle.isReusable && lifecycle.isResizable && !lifecycle.isReleasedWhenClosed)
        precondition(lifecycle.frameAutosaveName == "CoucouMemoryManagerWindow")
        var pendingSearch = MemoryManagerPresentationState()
        pendingSearch.present(query: "before-appearance")
        precondition(pendingSearch.consumePendingQuery() == "before-appearance")
        precondition(pendingSearch.consumePendingQuery() == nil)
        var requestState = MemoryManagerRequestState()
        let delayedList = requestState.beginList()
        let firstDetail = requestState.beginDetail(id: "old")
        precondition(requestState.isListLoading, "detail selection stopped list spinner")
        let secondDetail = requestState.beginDetail(id: "new")
        precondition(!requestState.acceptsDetail(firstDetail, id: "old"))
        precondition(requestState.acceptsDetail(secondDetail, id: "new"))
        precondition(requestState.finishList(delayedList) && !requestState.isListLoading)
        let staleList = requestState.beginList()
        let currentList = requestState.beginList()
        precondition(!requestState.finishList(staleList) && requestState.isListLoading)
        precondition(requestState.finishList(currentList) && !requestState.isListLoading)

        let failingBackend = TestKeychainBackend(values: [hindsightBearerTokenKey: "old"], writeStatus: -50, deleteStatus: -50)
        let failingStore = KeychainStore(backend: failingBackend, keys: [hindsightBearerTokenKey])
        precondition(failingStore.get(hindsightBearerTokenKey) == "old")
        if case .success = failingStore.set(hindsightBearerTokenKey, value: "new") { preconditionFailure("failed write succeeded") }
        precondition(failingStore.get(hindsightBearerTokenKey) == "old")
        if case .success = failingStore.remove(hindsightBearerTokenKey) { preconditionFailure("failed delete succeeded") }
        precondition(failingStore.get(hindsightBearerTokenKey) == "old")
        let successfulBackend = TestKeychainBackend(values: [:], writeStatus: 0, deleteStatus: -25300)
        let successfulStore = KeychainStore(backend: successfulBackend, keys: [hindsightBearerTokenKey])
        if case .failure(let error) = successfulStore.set(hindsightBearerTokenKey, value: "new") { preconditionFailure(error.localizedDescription) }
        precondition(successfulStore.get(hindsightBearerTokenKey) == "new")
        if case .failure(let error) = successfulStore.remove(hindsightBearerTokenKey) { preconditionFailure(error.localizedDescription) }
        precondition(successfulStore.get(hindsightBearerTokenKey) == nil)

        var credentialPresentation = HindsightCredentialPresentation(isStored: true)
        precondition(credentialPresentation.replacement.isEmpty && credentialPresentation.isStored)
        credentialPresentation.replacement = "never-read-back"
        credentialPresentation.didStoreReplacement()
        precondition(credentialPresentation.replacement.isEmpty && credentialPresentation.isStored)
        credentialPresentation.didRemove()
        precondition(credentialPresentation.replacement.isEmpty && !credentialPresentation.isStored)

        let confirmedRequest = MemoryBrowseRequest(
            filter: MemoryFilter(query: "tea", state: .valid, platform: .macos), limit: 25, offset: 75)
        let confirmedScope = try ConfirmedMemoryScope(request: confirmedRequest, config: config)
        try confirmedScope.validate(current: config)
        var changedBank = config
        changedBank.bank = "other"
        await expectServiceError(.conflict, "changed confirmed bank") {
            try confirmedScope.validate(current: changedBank)
        }
        var tamperedScope = confirmedScope
        tamperedScope.request.offset = 0
        await expectServiceError(.invalidConfiguration, "tampered confirmed scope") {
            try tamperedScope.validate(current: config)
        }
        precondition(confirmedScope.request.offset == 75 && confirmedScope.request.filter.state == .valid)

        let managerPage = Data("{\"items\":[{\"id\":\"newest\",\"text\":\"newest\",\"fact_type\":\"world\"},{\"id\":\"older\",\"text\":\"older\",\"fact_type\":\"world\"}],\"total\":42,\"limit\":25,\"offset\":50}".utf8)
        let managerChanged = Data("{\"id\":\"m1\",\"text\":\"changed remotely\",\"fact_type\":\"world\",\"state\":\"valid\",\"updated_at\":\"v2\"}".utf8)
        let managerUpdated = Data("{\"id\":\"m1\",\"text\":\"local edit\",\"fact_type\":\"world\",\"state\":\"valid\",\"updated_at\":\"v3\"}".utf8)
        let managerTransport = ScriptedTransport([.response(200, managerPage), .response(200, managerChanged), .response(200, managerChanged), .response(200, managerUpdated)])
        let managerService = try HindsightService(config: config, token: "secret", transport: managerTransport)
        let managerFilter = MemoryFilter(query: "tea", factType: .experience, startDate: "2026-01-01", endDate: "2026-02-01", timeField: .mentionedAt, platform: .macos, retentionKind: .explicit, sourceKind: .chat)
        let managerResult = try await managerService.memoryList(MemoryBrowseRequest(filter: managerFilter, limit: 25, offset: 50))
        precondition(managerResult.total == 42 && managerResult.limit == 25 && managerResult.offset == 50)
        precondition(managerResult.items.map(\.id) == ["newest", "older"], "newest-first server order changed")
        let opened = MemoryRecord(id: "m1", text: "opened", factType: .world, state: .valid, metadata: [:], tags: [], entities: [], updatedAt: "v1", sourceFactIds: [])
        let conflict = try await managerService.memoryUpdate(id: "m1", opened: opened, update: MemoryUpdate(text: "local edit"), overwrite: false)
        guard case .conflict(let current) = conflict else { preconditionFailure("changed reload did not conflict") }
        precondition(current.text == "changed remotely")
        let applied = try await managerService.memoryUpdate(id: "m1", opened: opened, update: MemoryUpdate(text: "local edit"), overwrite: true)
        guard case .updated(let changed, let refresh) = applied else { preconditionFailure("explicit overwrite did not update") }
        precondition(changed.text == "local edit" && refresh)
        let managerRequests = await managerTransport.requests
        let managerQuery = managerRequests[0].url!.query!
        for expected in ["q=tea", "type=experience", "state=valid", "start_date=2026-01-01", "end_date=2026-02-01", "time_field=mentioned_at", "tags=coucou:platform:macos", "tags=coucou:retention:explicit", "tags=coucou:source:chat", "tags_match=all", "limit=25", "offset=50"] {
            precondition(managerQuery.removingPercentEncoding!.contains(expected), "missing \(expected)")
        }

        let observation = MemoryRecord(id: "o1", text: "generated", factType: .observation, state: .valid, metadata: [:], tags: [], entities: [], sourceFactIds: [])
        let observationTransport = ScriptedTransport([])
        let observationService = try HindsightService(config: config, token: "secret", transport: observationTransport)
        await expectServiceError(.invalidConfiguration, "observation edit") {
            _ = try await observationService.memoryUpdate(id: "o1", opened: observation, update: MemoryUpdate(text: "no"), overwrite: true)
        }
        precondition((await observationTransport.requests).isEmpty)

        let currentObservation = Data("{\"id\":\"m1\",\"text\":\"generated\",\"fact_type\":\"observation\",\"state\":\"valid\",\"updated_at\":\"v2\"}".utf8)
        let currentObservationTransport = ScriptedTransport([.response(200, currentObservation)])
        let currentObservationService = try HindsightService(config: config, token: "secret", transport: currentObservationTransport)
        await expectServiceError(.invalidConfiguration, "current observation overwrite") {
            _ = try await currentObservationService.memoryUpdate(id: "m1", opened: opened, update: MemoryUpdate(text: "overwrite"), overwrite: true)
        }
        let currentObservationRequests = await currentObservationTransport.requests
        precondition(currentObservationRequests.count == 1 && currentObservationRequests[0].httpMethod == "GET")

        let racingService = try HindsightService(config: config, token: "secret", transport: RacingListTransport())
        async let stale = racingService.memoryList(MemoryBrowseRequest(filter: MemoryFilter(query: "old"), limit: 2, offset: 0))
        try? await Task.sleep(nanoseconds: 10_000_000)
        let newest = try await racingService.memoryList(MemoryBrowseRequest(filter: MemoryFilter(query: "new"), limit: 2, offset: 0))
        precondition(newest.items.map(\.id) == ["newest", "older"])
        await expectServiceError(.cancelled, "superseded list") { _ = try await stale }

        let bulkPage1 = Data("{\"items\":[{\"id\":\"a\",\"text\":\"a\",\"fact_type\":\"world\"},{\"id\":\"b\",\"text\":\"b\",\"fact_type\":\"world\"}],\"total\":1,\"limit\":2,\"offset\":0}".utf8)
        let bulkPage2 = Data("{\"items\":[{\"id\":\"b\",\"text\":\"b\",\"fact_type\":\"world\"},{\"id\":\"c\",\"text\":\"c\",\"fact_type\":\"world\"}],\"total\":1,\"limit\":2,\"offset\":2}".utf8)
        let bulkEnd = Data("{\"items\":[],\"total\":999,\"limit\":2,\"offset\":4}".utf8)
        let bulkRecord = Data("{\"id\":\"ok\",\"text\":\"x\",\"fact_type\":\"world\",\"state\":\"invalidated\"}".utf8)
        let bulkTransport = ScriptedTransport([.response(200, bulkPage1), .response(200, bulkPage2), .response(200, bulkEnd), .response(200, bulkRecord), .response(409, Data()), .response(200, bulkRecord)])
        let bulkService = try HindsightService(config: config, token: "secret", transport: bulkTransport)
        let bulkResult = try await bulkService.bulkRetire(options: MemoryListOptions(limit: 2, offset: 90))
        precondition(bulkResult.requested == 3 && bulkResult.failed.count == 1 && bulkResult.refresh)
        precondition(bulkResult.succeeded == ["a", "c"] && bulkResult.failed.map(\.id) == ["b"])
        let bulkRequests = await bulkTransport.requests
        precondition(bulkRequests[0].url?.query?.contains("offset=0") == true)
        for request in bulkRequests where request.httpMethod == "PATCH" {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            precondition(body["state"] as? String == "invalidated")
            precondition(body["reason"] as? String == "Retired from Coucou")
        }

        for limit in [0, -7] {
            let shortTransport = ScriptedTransport([.response(200, try memoryPage(["short"], offset: 0, limit: 100)), .response(200, bulkRecord)])
            let shortService = try HindsightService(config: config, token: "secret", transport: shortTransport)
            let shortResult = try await shortService.bulkRetire(options: MemoryListOptions(limit: limit))
            precondition(shortResult.requested == 1)
            let requests = await shortTransport.requests
            precondition(requests.count == 2, "short page made another list request")
            precondition(requests[0].url?.query?.contains("limit=100") == true, "limit \(limit) was not normalized")
        }

        let nonAdvancingTransport = ScriptedTransport([
            .response(200, try memoryPage(["a", "b"], offset: 0, limit: 2)),
            .response(200, try memoryPage(["c", "d"], offset: 0, limit: 2)),
        ])
        let nonAdvancingService = try HindsightService(config: config, token: "secret", transport: nonAdvancingTransport)
        await expectServiceError(.invalidResponse, "non-advancing bulk offset") {
            _ = try await nonAdvancingService.bulkRetire(options: MemoryListOptions(limit: 2))
        }

        let overflowTransport = ScriptedTransport([.response(200, try memoryPage(["a", "b"], offset: Int.max - 1, limit: 2))])
        let overflowService = try HindsightService(config: config, token: "secret", transport: overflowTransport)
        await expectServiceError(.invalidResponse, "bulk offset overflow") {
            _ = try await overflowService.bulkRetire(options: MemoryListOptions(limit: 2))
        }

        let cappedTransport = ScriptedTransport([
            .response(200, try memoryPage(["a"], offset: 0, limit: 1)),
            .response(200, try memoryPage(["b"], offset: 1, limit: 1)),
        ])
        let cappedService = try HindsightService(config: config, token: "secret", transport: cappedTransport, maxBulkPages: 2)
        await expectServiceError(.invalidResponse, "bulk page cap") {
            _ = try await cappedService.bulkRetire(options: MemoryListOptions(limit: 1))
        }
        let cappedRequests = await cappedTransport.requests
        precondition(cappedRequests.count == 2)

        let patchRecord = Data("{\"id\":\"m1\",\"text\":\"x\",\"fact_type\":\"world\",\"state\":\"invalidated\"}".utf8)
        let patchTransport = ScriptedTransport([.response(200, patchRecord), .response(200, patchRecord)])
        let patchService = try HindsightService(config: config, token: "secret", transport: patchTransport)
        precondition(try await patchService.memoryRetire(id: "m1").refresh)
        precondition(try await patchService.memoryRestore(id: "m1").refresh)
        let patchRequests = await patchTransport.requests
        let retireJSON = try JSONSerialization.jsonObject(with: patchRequests[0].httpBody!) as! [String: Any]
        let restoreJSON = try JSONSerialization.jsonObject(with: patchRequests[1].httpBody!) as! [String: Any]
        precondition(retireJSON["state"] as? String == "invalidated" && retireJSON["reason"] as? String == "Retired from Coucou")
        precondition(restoreJSON["state"] as? String == "valid")
        precondition((await patchTransport.headerTimeouts).allSatisfy { $0 == 5 })

        for (status, expected) in [(401, MemoryErrorKind.unauthorized), (403, .forbidden), (404, .notFound), (409, .conflict), (429, .rateLimited), (503, .unavailable)] {
            HindsightTestURLProtocol.enqueue([.init(status: status)])
            let real = try HindsightService(config: config, token: "secret", transport: productionTransport(), headerTimeout: 0.2)
            await expectServiceError(expected, "production status \(status)") { try await real.testConnection() }
        }
        HindsightTestURLProtocol.enqueue([.init(error: URLError(.cannotConnectToHost))])
        let connectionFailure = try HindsightService(config: config, token: "secret", transport: productionTransport(), headerTimeout: 0.2)
        await expectServiceError(.connection, "production connection failure") { try await connectionFailure.testConnection() }
        HindsightTestURLProtocol.enqueue([.init(chunks: [Data("bad-json".utf8)])])
        let malformedProduction = try HindsightService(config: config, token: "secret", transport: productionTransport(), headerTimeout: 0.2)
        await expectServiceError(.invalidResponse, "production malformed JSON") { try await malformedProduction.testConnection() }
        HindsightTestURLProtocol.enqueue([.init(chunks: [Data(repeating: 1, count: HindsightService.maxResponseBytes), Data([1])])])
        let oversizedProduction = try HindsightService(config: config, token: "secret", transport: productionTransport(), headerTimeout: 0.2)
        await expectServiceError(.invalidResponse, "production chunk overflow") { try await oversizedProduction.testConnection() }
        HindsightTestURLProtocol.enqueue([.init(headerDelay: 0.1)])
        let delayedHeaders = try HindsightService(config: config, token: "secret", transport: productionTransport(), headerTimeout: 0.01)
        await expectServiceError(.timeout, "production delayed headers") { try await delayedHeaders.testConnection() }
        HindsightTestURLProtocol.enqueue([.init(chunks: [emptyPage], bodyDelay: 0.05)])
        try await HindsightService(config: config, token: "secret", transport: productionTransport(), headerTimeout: 0.01).testConnection()
        HindsightTestURLProtocol.enqueue([.init(chunks: [emptyPage], bodyDelay: 1)])
        let cancelled = Task { try await HindsightService(config: config, token: "secret", transport: productionTransport(), headerTimeout: 0.2).testConnection() }
        cancelled.cancel()
        await expectServiceError(.cancelled, "production cancellation before task installation") { try await cancelled.value }
        HindsightTestURLProtocol.enqueue([.init(chunks: [emptyPage], bodyDelay: 1)])
        let cancelledAfter = Task { try await HindsightService(config: config, token: "secret", transport: productionTransport(), headerTimeout: 0.2).testConnection() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        cancelledAfter.cancel()
        await expectServiceError(.cancelled, "production cancellation after task installation") { try await cancelledAfter.value }

        print("Hindsight cross-platform contract: full fixture suite passed")
    }
}
