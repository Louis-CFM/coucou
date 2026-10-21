import Foundation

// Minimal decoders for the `orca ... --json` envelopes. Only the fields the derivation needs are
// declared, so prompt / toolInput / emails / ids never enter memory as Swift values.
// Unknown fields are ignored and missing ones become nil (contract: tolerate format drift).

struct OrcaEnvelope<Result: Decodable>: Decodable {
    var ok: Bool?
    var result: Result?
    var error: ErrorBody?
    struct ErrorBody: Decodable { var code: String?; var message: String? }
}

struct RawWorktreesResult: Decodable { var worktrees: [RawWorktree]? }

struct RawWorktree: Decodable {
    var worktreeId: String?
    var repo: String?
    var displayName: String?
    var branch: String?
    var hostId: String?
    var isArchived: Bool?
    var workspaceStatus: String?
    var status: String?
    var terminalVerdict: String?
    var unread: Bool?
    var comment: String?
    var liveTerminalCount: Int?
    var lastActivityAt: Double?
    var lastOutputAt: Double?
    var linkedPR: RawPR?
    var agents: [RawAgent]?

    struct RawPR: Decodable { var number: Int?; var state: String? }
    struct RawAgent: Decodable {
        var agentType: String?
        var state: String?
        var stateStartedAt: Double?
        var toolName: String?
        var lastAssistantMessage: String?
    }
}

struct RawAccountsResult: Decodable {
    var rateLimits: [String: RawRateLimit]?

    private enum CodingKeys: String, CodingKey { case rateLimits }
    private struct Lossy: Decodable {
        var value: RawRateLimit?
        init(from decoder: Decoder) throws { value = try? RawRateLimit(from: decoder) }
    }

    /// Real output mixes non-object values into `rateLimits`; skip anything that is not a provider entry.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let lossy = try c.decodeIfPresent([String: Lossy].self, forKey: .rateLimits)
        rateLimits = lossy?.compactMapValues(\.value)
    }
}

struct RawRateLimit: Decodable {
    var provider: String?
    var session: RawWindow?
    var weekly: RawWindow?
    struct RawWindow: Decodable {
        var usedPercent: Double?
        var resetsAt: Double?   // milliseconds
    }
}

struct RawWorkersResult: Decodable {
    var workers: [RawWorker]?
    var page: Page?
    struct Page: Decodable { var hasMore: Bool?; var nextCursor: String? }
}

struct RawWorker: Decodable {
    var taskId: String?
    var projection: Projection?
    struct Projection: Decodable {
        var outcome: String?
        var workspace: Workspace?
        var host: Host?
        var stage: Stage?
        var liveness: Liveness?
        var evidence: Evidence?
        var attention: Attention?
    }
    struct Workspace: Decodable { var id: String? }
    struct Host: Decodable { var id: String? }
    struct Stage: Decodable { var detail: String? }
    struct Liveness: Decodable { var verdict: String?; var observedAt: Double? }
    struct Evidence: Decodable { var lastObservedAt: Double? }
    struct Attention: Decodable { var requiresAction: Bool? }
}

struct RawStatusResult: Decodable {
    var runtime: Runtime?
    struct Runtime: Decodable { var state: String?; var reachable: Bool?; var appVersion: String? }
}

/// Last good value of each source (raw, already stripped to the fields above).
struct OrcaRawState: Sendable {
    var worktrees: [RawWorktree] = []
    var rateLimits: [String: RawRateLimit] = [:]
    var workers: [RawWorker] = []
    var status: RawStatusResult.Runtime?
}
