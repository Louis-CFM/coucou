import Foundation

let hindsightBearerTokenKey = "hindsight-bearer-token"

struct HindsightConfig: Codable, Equatable {
    var enabled: Bool
    var baseUrl: String
    var tenant: String
    var bank: String
    var automaticRecall: Bool
    var inferredRetention: Bool
    var allowDevelopmentHttp: Bool

    static let defaults = HindsightConfig(
        enabled: false,
        baseUrl: "https://hindsight.example.com/hindsight",
        tenant: "default",
        bank: "hieu",
        automaticRecall: true,
        inferredRetention: true,
        allowDevelopmentHttp: false
    )
}

typealias HindsightSettings = HindsightConfig

enum MemoryFactType: String, Codable { case world, experience, observation }
enum MemoryState: String, Codable { case valid, invalidated }
enum RetentionKind: String, Codable { case explicit, inferred }
enum MemoryPlatform: String, Codable { case windows, macos }
enum MemoryTimeField: String, Codable {
    case createdAt = "created_at", updatedAt = "updated_at", mentionedAt = "mentioned_at"
    case occurredStart = "occurred_start", occurredEnd = "occurred_end", editedAt = "edited_at"
}
enum MemorySourceKind: String, Codable { case chat, selectedText = "selected-text" }

enum JSONValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(Double.self) { self = .number(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode([String: JSONValue].self) { self = .object(decoded) }
        else { self = .array(try value.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let decoded): try value.encode(decoded)
        case .number(let decoded): try value.encode(decoded)
        case .bool(let decoded): try value.encode(decoded)
        case .object(let decoded): try value.encode(decoded)
        case .array(let decoded): try value.encode(decoded)
        case .null: try value.encodeNil()
        }
    }
}

struct MemoryRecord: Codable, Equatable {
    var id: String
    var text: String
    var factType: MemoryFactType
    var state: MemoryState
    var context: String? = nil
    var metadata: [String: JSONValue]
    var tags: [String]
    var entities: [String]
    var documentId: String? = nil
    var chunkId: String? = nil
    var createdAt: String? = nil
    var updatedAt: String? = nil
    var mentionedAt: String? = nil
    var occurredStart: String? = nil
    var occurredEnd: String? = nil
    var editedAt: String? = nil
    var sourceFactIds: [String]
}

struct MemoryPage: Codable, Equatable {
    var items: [MemoryRecord]
    var total: Int
    var limit: Int
    var offset: Int
}

struct HindsightRecallMemory: Decodable, Equatable {
    var text: String
    init(text: String) { self.text = text }
}

struct HindsightRecallResponse: Decodable, Equatable {
    var text: String?
    var memories: [HindsightRecallMemory]

    private enum CodingKeys: String, CodingKey { case text, memories }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        let values = try container.decodeIfPresent([JSONValue].self, forKey: .memories) ?? []
        memories = values.compactMap { value in
            guard case .object(let object) = value, case .string(let text) = object["text"] else { return nil }
            return .init(text: text)
        }
    }
}

let safeMemoryMetadataKeys: Set<String> = [
    "coucou.turnId", "coucou.timestamp", "coucou.platform", "coucou.provider", "coucou.model",
    "coucou.contextKind", "coucou.contextLabel", "coucou.retentionKind", "coucou.sourceRole",
    "coucou.sourceSpan", "coucou.tenant", "coucou.bank", "coucou.remoteIds", "coucou.remoteTimestamp",
]
let safeMemoryCollectionLimit = 64
let safeMemoryValueLimit = 256
let safeMemoryIdentifierLimit = 512
private func boundedSafeValues(_ values: [String]) -> [String] { Array(values.prefix(safeMemoryCollectionLimit)).map { String($0.prefix(safeMemoryValueLimit)) } }
private func boundedSafeIdentifier(_ value: String?) -> String? { value.map { String($0.prefix(safeMemoryIdentifierLimit)) } }
private func boundedSafeValue(_ value: String?) -> String? { value.map { String($0.prefix(safeMemoryValueLimit)) } }

struct SafeMemoryDetail: Equatable {
    let id: String, content: String, tenant: String, bank: String
    let factType: MemoryFactType, state: MemoryState
    let context: String?
    let tags, entities, sourceFactIds: [String]
    let createdAt, updatedAt, mentionedAt, occurredStart, occurredEnd, editedAt: String?
    let metadata: [String: String]
    let documentId, chunkId: String?

    init(record: MemoryRecord, tenant: String, bank: String, contentLimit: Int = 16_384) {
        id = String(record.id.prefix(safeMemoryIdentifierLimit)); content = String(record.text.prefix(contentLimit)); self.tenant = tenant; self.bank = bank
        factType = record.factType; state = record.state; context = record.context.map { String($0.prefix(contentLimit)) }
        tags = boundedSafeValues(record.tags); entities = boundedSafeValues(record.entities); sourceFactIds = boundedSafeValues(record.sourceFactIds)
        createdAt = boundedSafeValue(record.createdAt); updatedAt = boundedSafeValue(record.updatedAt); mentionedAt = boundedSafeValue(record.mentionedAt)
        occurredStart = boundedSafeValue(record.occurredStart); occurredEnd = boundedSafeValue(record.occurredEnd); editedAt = boundedSafeValue(record.editedAt)
        metadata = record.metadata.reduce(into: [:]) { result, pair in if safeMemoryMetadataKeys.contains(pair.key), case .string(let value) = pair.value { result[pair.key] = String(value.prefix(safeMemoryValueLimit)) } }
        documentId = boundedSafeIdentifier(record.documentId); chunkId = boundedSafeIdentifier(record.chunkId)
    }
}

struct ConfirmedMemoryRetirement: Equatable {
    let id, text, endpoint, tenant, bank: String
    let updatedAt: String?
    init(record: MemoryRecord, config: HindsightConfig) throws { id = record.id; text = record.text; updatedAt = record.updatedAt; endpoint = try normalizedHindsightEndpoint(config); tenant = config.tenant; bank = config.bank }
}

struct MemoryFilter: Codable, Equatable {
    var query: String? = nil
    var documentId: String? = nil
    var factType: MemoryFactType? = nil
    var state: MemoryState = .valid
    var startDate: String? = nil
    var endDate: String? = nil
    var timeField: MemoryTimeField? = nil
    var platform: MemoryPlatform? = nil
    var retentionKind: RetentionKind? = nil
    var sourceKind: MemorySourceKind? = nil

    private enum CodingKeys: String, CodingKey {
        case query, documentId, factType, state, startDate, endDate, timeField, platform, retentionKind, sourceKind
    }

    init(
        query: String? = nil, documentId: String? = nil, factType: MemoryFactType? = nil, state: MemoryState = .valid,
        startDate: String? = nil, endDate: String? = nil, timeField: MemoryTimeField? = nil,
        platform: MemoryPlatform? = nil, retentionKind: RetentionKind? = nil, sourceKind: MemorySourceKind? = nil
    ) {
        self.query = query
        self.documentId = documentId
        self.factType = factType
        self.state = state
        self.startDate = startDate
        self.endDate = endDate
        self.timeField = timeField
        self.platform = platform
        self.retentionKind = retentionKind
        self.sourceKind = sourceKind
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        query = try values.decodeIfPresent(String.self, forKey: .query)
        documentId = try values.decodeIfPresent(String.self, forKey: .documentId)
        factType = try values.decodeIfPresent(MemoryFactType.self, forKey: .factType)
        state = try values.decodeIfPresent(MemoryState.self, forKey: .state) ?? .valid
        startDate = try values.decodeIfPresent(String.self, forKey: .startDate)
        endDate = try values.decodeIfPresent(String.self, forKey: .endDate)
        timeField = try values.decodeIfPresent(MemoryTimeField.self, forKey: .timeField)
        platform = try values.decodeIfPresent(MemoryPlatform.self, forKey: .platform)
        retentionKind = try values.decodeIfPresent(RetentionKind.self, forKey: .retentionKind)
        sourceKind = try values.decodeIfPresent(MemorySourceKind.self, forKey: .sourceKind)
    }
}

struct MemoryUpdate: Codable, Equatable {
    var text: String? = nil
    var context: String? = nil
    var occurredStart: String? = nil
    var occurredEnd: String? = nil
    var factType: MemoryFactType? = nil
    var entities: [String]? = nil
    var resolveEntities: Bool = false
    var state: MemoryState? = nil
    var reason: String? = nil
    var expectedUpdatedAt: String? = nil

    private enum CodingKeys: String, CodingKey {
        case text, context, occurredStart, occurredEnd, factType, entities, resolveEntities, state, reason, expectedUpdatedAt
    }

    init(
        text: String? = nil, context: String? = nil, occurredStart: String? = nil, occurredEnd: String? = nil,
        factType: MemoryFactType? = nil, entities: [String]? = nil, resolveEntities: Bool = false,
        state: MemoryState? = nil, reason: String? = nil, expectedUpdatedAt: String? = nil
    ) {
        self.text = text
        self.context = context
        self.occurredStart = occurredStart
        self.occurredEnd = occurredEnd
        self.factType = factType
        self.entities = entities
        self.resolveEntities = resolveEntities
        self.state = state
        self.reason = reason
        self.expectedUpdatedAt = expectedUpdatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        text = try values.decodeIfPresent(String.self, forKey: .text)
        context = try values.decodeIfPresent(String.self, forKey: .context)
        occurredStart = try values.decodeIfPresent(String.self, forKey: .occurredStart)
        occurredEnd = try values.decodeIfPresent(String.self, forKey: .occurredEnd)
        factType = try values.decodeIfPresent(MemoryFactType.self, forKey: .factType)
        entities = try values.decodeIfPresent([String].self, forKey: .entities)
        resolveEntities = try values.decodeIfPresent(Bool.self, forKey: .resolveEntities) ?? false
        state = try values.decodeIfPresent(MemoryState.self, forKey: .state)
        reason = try values.decodeIfPresent(String.self, forKey: .reason)
        expectedUpdatedAt = try values.decodeIfPresent(String.self, forKey: .expectedUpdatedAt)
    }
}

func hindsightTextContainsSecret(_ text: String) -> Bool {
    let value = text.lowercased()
    if ["authorization:", "bearer ", "api key", "api_key", "password", "private key", "-----begin", "postgres://", "postgresql://", "mysql://", "mongodb://", "redis://", "jdbc:", "token =", "token=", "token:", "system prompt", "hidden prompt", "developer message", "internal instructions", "tool definitions", "ignore prior instructions"].contains(where: value.contains) { return true }
    return text.split(whereSeparator: \Character.isWhitespace).contains { raw in
        let token = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.+/=").inverted)
        if token.hasPrefix("AKIA") && token.count >= 20 { return true }
        if token.lowercased().hasPrefix("sk-") && token.count >= 16 { return true }
        if token.filter({ $0 == "." }).count == 2 && token.count >= 32 { return true }
        guard token.count >= 24 else { return false }
        return token.contains(where: \Character.isLowercase) && token.contains(where: \Character.isUppercase) && token.contains(where: \Character.isNumber)
    }
}

enum MemoryErrorKind: String, Codable {
    case disabled, authenticationRequired, forbidden, invalidConfiguration, tls, connection, timeout
    case server, invalidResponse, oversized, conflict, partial, cancelled, notFound, rateLimited
    static let unauthorized = authenticationRequired
    static let unavailable = server
    static let network = connection
}

enum HindsightConfigError: Error { case invalidBaseURL, insecureHTTP, unsafeSegment }

func validateHindsightConfig(_ config: HindsightConfig) throws {
    try validateHindsightSegment(config.tenant)
    try validateHindsightSegment(config.bank)
    guard let components = URLComponents(string: config.baseUrl),
          let scheme = components.scheme?.lowercased(),
          let host = components.host, !host.isEmpty,
          components.user == nil, components.password == nil,
          components.query == nil, components.fragment == nil else {
        throw HindsightConfigError.invalidBaseURL
    }
    guard scheme == "https" || (scheme == "http" && config.allowDevelopmentHttp) else {
        throw HindsightConfigError.insecureHTTP
    }
}

func normalizedHindsightEndpoint(_ config: HindsightConfig) throws -> String {
    try validateHindsightConfig(config)
    guard var components = URLComponents(string: config.baseUrl), let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased() else { throw HindsightConfigError.invalidBaseURL }
    components.scheme = scheme
    components.host = host
    if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) { components.port = nil }
    let path = components.percentEncodedPath
    components.percentEncodedPath = path == "/" ? "" : path.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    guard let value = components.string else { throw HindsightConfigError.invalidBaseURL }
    return value
}

func hindsightURL(config: HindsightConfig, suffix: [String]) throws -> URL {
    try validateHindsightConfig(config)
    guard var url = URL(string: config.baseUrl) else { throw HindsightConfigError.invalidBaseURL }
    for segment in ["v1", config.tenant, "banks", config.bank] + suffix {
        try validateHindsightSegment(segment)
        url.appendPathComponent(segment)
    }
    return url
}

private func validateHindsightSegment(_ value: String) throws {
    let lower = value.lowercased()
    guard !value.isEmpty,
          value.rangeOfCharacter(from: .controlCharacters) == nil,
          !value.contains("/"), !value.contains("\\"),
          !lower.contains("%2f"), !lower.contains("%5c") else {
        throw HindsightConfigError.unsafeSegment
    }
}
