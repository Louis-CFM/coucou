import Foundation

enum AppSessionDefaults {
    static let privateChat = false
}

enum HindsightCredentialReplacement {
    static func store(_ token: String) -> Result<Void, KeychainStoreError> {
        let result = KeychainStore.shared.set(hindsightBearerTokenKey, value: token)
        if case .success = result { HindsightService.clearAutomaticAuthenticationSuppression() }
        return result
    }
}

struct HindsightCredentialPresentation: Equatable {
    var replacement = ""
    private(set) var isStored: Bool

    init(isStored: Bool) {
        self.isStored = isStored
    }

    mutating func didStoreReplacement() {
        replacement = ""
        isStored = true
    }

    mutating func didRemove() {
        replacement = ""
        isStored = false
    }
}

struct ConfirmedMemoryScope: Codable, Equatable {
    var request: MemoryBrowseRequest
    let endpoint: String
    let tenant: String
    let bank: String
    let fingerprint: String

    init(request: MemoryBrowseRequest, config: HindsightConfig) throws {
        var validRequest = request
        validRequest.filter.state = .valid
        self.request = validRequest
        endpoint = try normalizedHindsightEndpoint(config)
        tenant = config.tenant
        bank = config.bank
        fingerprint = try Self.makeFingerprint(request: validRequest, endpoint: endpoint, tenant: tenant, bank: bank)
    }

    func validate(current config: HindsightConfig) throws {
        guard request.filter.state == .valid,
              fingerprint == (try Self.makeFingerprint(request: request, endpoint: endpoint, tenant: tenant, bank: bank)) else {
            throw HindsightServiceError(kind: .invalidConfiguration, message: "Confirmed memory scope changed")
        }
        guard try normalizedHindsightEndpoint(config) == endpoint, config.tenant == tenant, config.bank == bank else {
            throw HindsightServiceError(kind: .conflict, message: "Hindsight endpoint, tenant, or bank changed after confirmation")
        }
    }

    private static func makeFingerprint(request: MemoryBrowseRequest, endpoint: String, tenant: String, bank: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return endpoint + "\n" + tenant + "\n" + bank + "\n" + String(decoding: try encoder.encode(request), as: UTF8.self)
    }
}

struct MemoryManagerWindowDescriptor: Equatable {
    let isSingleton: Bool
    let isReusable: Bool
    let isResizable: Bool
    let isReleasedWhenClosed: Bool
    let frameAutosaveName: String
}

func memoryManagerWindowConfiguration() -> MemoryManagerWindowDescriptor {
    MemoryManagerWindowDescriptor(
        isSingleton: true,
        isReusable: true,
        isResizable: true,
        isReleasedWhenClosed: false,
        frameAutosaveName: "CoucouMemoryManagerWindow"
    )
}

struct MemoryManagerRequestState: Equatable {
    private(set) var listGeneration: UInt64 = 0
    private(set) var detailGeneration: UInt64 = 0
    private(set) var selectedID: String?
    private(set) var isListLoading = false

    mutating func beginList() -> UInt64 {
        listGeneration &+= 1
        detailGeneration &+= 1
        selectedID = nil
        isListLoading = true
        return listGeneration
    }

    mutating func finishList(_ generation: UInt64) -> Bool {
        guard generation == listGeneration else { return false }
        isListLoading = false
        return true
    }

    mutating func beginDetail(id: String) -> UInt64 {
        detailGeneration &+= 1
        selectedID = id
        return detailGeneration
    }

    func acceptsDetail(_ generation: UInt64, id: String) -> Bool {
        generation == detailGeneration && id == selectedID
    }
}

struct MemoryManagerPresentationState: Equatable {
    private(set) var pendingQuery: String?

    mutating func present(query: String?) {
        if let query, !query.isEmpty { pendingQuery = query }
    }

    mutating func consumePendingQuery() -> String? {
        defer { pendingQuery = nil }
        return pendingQuery
    }
}

enum ControlledTextRole: String, Codable, Equatable { case user, assistant }

struct ControlledTextSelection: Equatable {
    let text: String
    let utf8Start: Int
    let utf8End: Int
    let role: ControlledTextRole

    func validated(in source: String) -> ControlledTextSelection? {
        guard !text.isEmpty, utf8Start >= 0, utf8Start < utf8End,
              let start = source.utf8.index(source.utf8.startIndex, offsetBy: utf8Start, limitedBy: source.utf8.endIndex),
              let end = source.utf8.index(source.utf8.startIndex, offsetBy: utf8End, limitedBy: source.utf8.endIndex),
              let scalarStart = String.Index(start, within: source),
              let scalarEnd = String.Index(end, within: source),
              String(source[scalarStart..<scalarEnd]) == text else { return nil }
        return self
    }
}
