import Foundation

enum ChatContextKind: Equatable { case none, window, file }

enum ChatProviderContext: Equatable {
    case window(appName: String, title: String, url: String?)
    case file(name: String, path: String?, bytes: Data?)
    var kind: ChatContextKind { switch self { case .window: return .window; case .file: return .file } }
}

enum ChatMemorySaveStatus: String { case saving, saved, notSaved }
enum ArtifactSourceKind: String, Equatable { case chat, selectedText = "selected-text" }
enum ArtifactDiscoveryState: String, Equatable { case discovering, saved, empty, partial, retired }

struct RemoteArtifactRecord: Equatable { let id: String; let timestamp: String? }

struct RetainedArtifact: Equatable {
    let documentId: String
    var remoteIds: [String]
    let retentionKind: RetentionKind
    let sourceKind: ArtifactSourceKind
    let config: HindsightConfig
    let generation: UInt64
    var discoveryState: ArtifactDiscoveryState
    var remoteTimestamps: [String]

    static func pending(documentId: String, retentionKind: RetentionKind, sourceKind: ArtifactSourceKind, config: HindsightConfig, generation: UInt64) -> RetainedArtifact {
        .init(documentId: documentId, remoteIds: [], retentionKind: retentionKind, sourceKind: sourceKind, config: config, generation: generation, discoveryState: .discovering, remoteTimestamps: [])
    }
    func withRemoteIds(_ ids: [String]) -> RetainedArtifact { var value = self; value.remoteIds = ids; value.discoveryState = ids.isEmpty ? .empty : .saved; return value }
}

enum ArtifactSummaryState: String, Equatable { case discovering, saved, partial, retired }
struct ArtifactSummary: Equatable {
    let state: ArtifactSummaryState
    let artifactCount, remoteIdCount: Int
    let documentIds, remoteIds: [String]
    let tenant, bank: String
}

enum ForgetFallback: String, Equatable { case document, text }
struct ForgetFailure: Equatable { let id, message: String }
struct DiscoveryFailure: Equatable { let documentId: String; let kind: MemoryErrorKind; let message: String }
struct PreparedForgetTurn: Equatable { let turnId: String; let generation: UInt64; let endpoint, tenant, bank: String; let knownIds, documentIds: [String]; let artifactFingerprint: String }
struct ForgetPlan: Equatable { let ids, documentIds: [String]; let discoveryFailures: [DiscoveryFailure]; let fallback: ForgetFallback? }
struct ForgetTurnResult: Equatable { let succeeded: [String]; let failed: [ForgetFailure]; let discoveryFailures: [DiscoveryFailure]; let documentIds: [String]; let fallback: ForgetFallback? }

func deduplicated(_ values: [String]) -> [String] { var seen = Set<String>(); return values.filter { seen.insert($0).inserted } }

func discoverRetainedArtifact(maxAttempts: Int = 4, poll: @Sendable () async throws -> [RemoteArtifactRecord], sleep: @Sendable (Int) async -> Void) async throws -> [RemoteArtifactRecord] {
    for attempt in 0..<max(1, maxAttempts) {
        try Task.checkCancellation()
        let records = try await poll()
        if !records.isEmpty || attempt + 1 == max(1, maxAttempts) {
            var seen = Set<String>()
            return records.filter { seen.insert($0.id).inserted }
        }
        await sleep(attempt)
    }
    return []
}

func planForgetTurn(artifacts: [RetainedArtifact], finalRecords: [RemoteArtifactRecord], discoveryFailures: [DiscoveryFailure] = []) -> ForgetPlan {
    let documents = deduplicated(artifacts.map(\.documentId))
    let ids = deduplicated(artifacts.flatMap(\.remoteIds) + finalRecords.map(\.id))
    let fallback: ForgetFallback? = ids.isEmpty && discoveryFailures.isEmpty ? (documents.isEmpty ? .text : .document) : nil
    return .init(ids: ids, documentIds: documents, discoveryFailures: discoveryFailures, fallback: fallback)
}
func finishForgetTurn(plan: ForgetPlan, succeeded: [String], failed: [ForgetFailure]) -> ForgetTurnResult { .init(succeeded: succeeded, failed: failed, discoveryFailures: plan.discoveryFailures, documentIds: plan.documentIds, fallback: plan.fallback) }
func forgetResultIsPartial(_ result: ForgetTurnResult) -> Bool { !result.failed.isEmpty || !result.discoveryFailures.isEmpty }

func completeDocumentUnion(documentIds: [String], pageSize: Int, maxPages: Int = 10_000, load: (String, Int, Int) async throws -> MemoryPage) async throws -> [MemoryRecord] {
    var result: [MemoryRecord] = []; var seen = Set<String>()
    for documentId in documentIds {
        var offset = 0
        for pageNumber in 0...maxPages {
            guard pageNumber < maxPages else { throw HindsightServiceError(kind: .invalidResponse, message: "Document pagination exceeded the maximum page count") }
            let page = try await load(documentId, pageSize, offset)
            for item in page.items where seen.insert(item.id).inserted { result.append(item) }
            if page.items.isEmpty || page.items.count < pageSize { break }
            let (next, overflow) = page.offset.addingReportingOverflow(page.items.count)
            guard !overflow, next > offset else { throw HindsightServiceError(kind: .invalidResponse, message: "Document pagination did not advance") }
            offset = next
        }
    }
    return result
}

func documentUnionPage(_ records: [MemoryRecord], limit: Int, offset: Int) -> MemoryPage {
    let start = min(max(0, offset), records.count); let end = min(start + max(0, limit), records.count)
    return .init(items: Array(records[start..<end]), total: records.count, limit: limit, offset: offset)
}

struct PendingChatMemoryStatuses {
    private let limit: Int
    private var values: [String: ChatMemorySaveStatus] = [:]
    private var order: [String] = []

    init(limit: Int = 128) { self.limit = max(1, limit) }
    var count: Int { values.count }
    func value(for turnId: String) -> ChatMemorySaveStatus? { values[turnId] }

    mutating func set(_ status: ChatMemorySaveStatus, for turnId: String) {
        order.removeAll { $0 == turnId }
        values[turnId] = status
        order.append(turnId)
        while order.count > limit { values.removeValue(forKey: order.removeFirst()) }
    }

    mutating func take(_ turnId: String) -> ChatMemorySaveStatus? {
        order.removeAll { $0 == turnId }
        return values.removeValue(forKey: turnId)
    }

    mutating func clear() {
        values.removeAll()
        order.removeAll()
    }

    mutating func apply(to turnId: String) -> ChatMemorySaveStatus? { take(turnId) }
}

struct ChatMemoryStatusHandoff {
    private struct TurnMessages {
        var user: ChatMemorySaveStatus?
        var assistant: ChatMemorySaveStatus?
    }

    private var pending = PendingChatMemoryStatuses(limit: 128)
    private var visible: [String: TurnMessages] = [:]

    mutating func receive(_ status: ChatMemorySaveStatus, turnId: String) {
        if visible[turnId] != nil { visible[turnId]?.assistant = status }
        else { pending.set(status, for: turnId) }
    }

    mutating func insertTurn(turnId: String) {
        visible[turnId] = TurnMessages(user: nil, assistant: pending.take(turnId))
    }

    func status(turnId: String, role: ControlledTextRole) -> ChatMemorySaveStatus? {
        switch role {
        case .user: return visible[turnId]?.user
        case .assistant: return visible[turnId]?.assistant
        }
    }

    mutating func clear() {
        pending.clear()
        visible.removeAll()
    }
}

struct ChatProviderSelection: Equatable {
    let provider: ChatProvider
    let model: String
}

struct ChatProviderRequest: Equatable {
    var query: String
    var contextKind: ChatContextKind
    var providerContext: ChatProviderContext?
    var memoryContext: String?
    var providerSelection: ChatProviderSelection
}

struct ChatProviderResult: Equatable {
    var text: String
    var completed: Bool
    var cancelled: Bool
    var hasToolMaterial: Bool
}

func claudeRequestParts(_ request: ChatProviderRequest, isFirstTurn: Bool) -> (userContent: [[String: Any]], memoryContext: String?) {
    var userContent: [[String: Any]] = []
    if isFirstTurn, let context = request.providerContext {
        switch context {
        case .window(let appName, let title, let url):
            var text = "Context — App: \(appName), Window: \(title)"; if let url { text += ", URL: \(url)" }
            userContent.append(["type": "text", "text": text])
        case .file(let name, _, _):
            userContent.append(["type": "text", "text": "File: \(name)"])
        }
    }
    userContent.append(["type": "text", "text": request.query])
    return (userContent, request.memoryContext)
}

@MainActor
protocol ChatProviderServing: AnyObject {
    func send(_ request: ChatProviderRequest) async throws -> ChatProviderResult
}

func anthropicSystemContent(trusted: String, memoryContext: String?) -> String {
    guard let memoryContext else { return trusted }
    return trusted + "\n\n" + memoryContext
}

func anthropicChatBody(model: String, trustedSystem: String, memoryContext: String?, tools: [[String: Any]], messages: [[String: Any]]) -> [String: Any] {
    ["model": model, "max_tokens": 4096, "tools": tools, "system": anthropicSystemContent(trusted: trustedSystem, memoryContext: memoryContext), "messages": messages]
}
