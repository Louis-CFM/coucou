import Foundation

// Public, privacy-safe model exposed by OrcaStore (rules from orca-monitor docs/api.md).
// Never holds e-mails, organization/account ids, prompts, toolInput, absolute paths or a full
// lastAssistantMessage. Dates are Unix epoch seconds.

public enum OrcaWorkspaceState: String, CaseIterable, Sendable, Codable {
    case failed, attention, running, review, done, idle

    /// Contract priority (lower = more important).
    public var priority: Int {
        switch self {
        case .failed: 0
        case .attention: 1
        case .running: 2
        case .review: 3
        case .done: 4
        case .idle: 5
        }
    }
}

public enum OrcaSource: String, CaseIterable, Sendable, Codable {
    case worktrees, accounts, workers, status
}

public struct OrcaSourceHealth: Equatable, Sendable {
    public var ok: Bool
    /// Epoch seconds of the last successful read (nil if never).
    public var lastSuccessAt: Int?
    /// Short, path-free error of the last attempt (nil when ok).
    public var error: String?

    public init(ok: Bool, lastSuccessAt: Int? = nil, error: String? = nil) {
        self.ok = ok
        self.lastSuccessAt = lastSuccessAt
        self.error = error
    }
}

public struct OrcaPullRequest: Equatable, Sendable {
    public var number: Int?
    public var state: String?
    public var isOpen: Bool { state == "open" }
}

/// What an agent means to the notch: the three counters plus `idle` (stale, not counted).
public enum OrcaAgentStatus: String, Sendable, Codable {
    /// Working (sidebar spinner).
    case running
    /// Done today and nothing waits on the user (sidebar check-circle).
    case finished
    /// Needs the user: unread result, waiting for input/permission, or failed (sidebar bell).
    case alert
    /// Done on a previous day, or waiting on a workspace that went quiet over 24 h ago.
    case idle
}

/// Agents (not workspaces) per counter.
public struct OrcaAgentCounts: Equatable, Sendable {
    public var running = 0
    public var finished = 0
    public var alert = 0

    public init(running: Int = 0, finished: Int = 0, alert: Int = 0) {
        self.running = running
        self.finished = finished
        self.alert = alert
    }

    public var total: Int { running + finished + alert }
    /// The closed island stays on screen only while something runs or waits on the user;
    /// finished agents alone are idle ("collapse as today").
    public var keepsIslandVisible: Bool { running > 0 || alert > 0 }
}

public struct OrcaAgent: Equatable, Sendable {
    public var type: String?
    public var state: String?
    public var since: Int?
    public var tool: String?
    /// `lastAssistantMessage` on one line, at most 160 characters.
    public var last: String?
    public var status: OrcaAgentStatus = .idle
    public var isWorking: Bool { state == "working" }
}

public struct OrcaWorkerSummary: Equatable, Sendable {
    public var taskId: String?
    /// Contract outcome: `succeeded`, `failed` or `running` (anything else).
    public var outcome: String
    public var stage: String?
    public var requiresAction: Bool
    /// Last known update (epoch seconds), when Orca exposes one.
    public var updatedAt: Int?
}

public struct OrcaWorkspace: Equatable, Sendable, Identifiable {
    /// `sha1(worktreeId)`, first 12 hex characters.
    public var key: String
    public var repo: String
    public var name: String
    public var branch: String?
    public var state: OrcaWorkspaceState
    public var workspaceStatus: String?
    public var comment: String?
    public var unread: Bool
    public var pr: OrcaPullRequest?
    public var liveTerminals: Int
    public var lastActivityAt: Int?
    public var isActive: Bool
    public var isRemote: Bool
    public var needsAttention: Bool
    public var agents: [OrcaAgent]
    public var workers: [OrcaWorkerSummary]

    public var id: String { key }
    public var hasRunningAgent: Bool { agents.contains { $0.isWorking } }
    /// Main agent: the first working one, else the first.
    public var primaryAgent: OrcaAgent? { agents.first(where: \.isWorking) ?? agents.first }
}

public struct OrcaCounts: Equatable, Sendable {
    public var active = 0
    /// Workspaces with at least one working agent.
    public var running = 0
    public var attention = 0
    public var doneToday = 0
    public var remote = 0
    /// Total working agents.
    public var runningAgents = 0
}

public struct OrcaWorkerCounts: Equatable, Sendable {
    public var succeeded = 0
    public var failed = 0
    public var running = 0
    public var requiresAction = 0
}

public struct OrcaUsageWindow: Equatable, Sendable {
    public var pct: Double
    public var resetsAt: Int?
    public var resetText: String?
}

public struct OrcaProviderUsage: Equatable, Sendable, Identifiable {
    public var provider: String
    public var label: String
    public var session: OrcaUsageWindow?
    public var weekly: OrcaUsageWindow?
    public var id: String { provider }
}

public struct OrcaRuntimeInfo: Equatable, Sendable {
    public var ok: Bool
    public var version: String?
}

public struct OrcaSnapshot: Equatable, Sendable {
    public var generatedAt: Int
    /// True when the last fully successful collection cycle is older than 3 poll intervals.
    public var stale: Bool
    public var orca: OrcaRuntimeInfo
    public var counts: OrcaCounts
    /// Per-agent counters of the closed island.
    public var agentCounts = OrcaAgentCounts()
    public var workers: OrcaWorkerCounts
    public var usage: [OrcaProviderUsage]
    /// Non-archived workspaces, by state priority then most recent activity.
    public var workspaces: [OrcaWorkspace]
    public var sources: [OrcaSource: OrcaSourceHealth]

    public static let empty = OrcaSnapshot(
        generatedAt: 0, stale: true, orca: OrcaRuntimeInfo(ok: false, version: nil),
        counts: OrcaCounts(), workers: OrcaWorkerCounts(), usage: [], workspaces: [],
        sources: Dictionary(uniqueKeysWithValues: OrcaSource.allCases.map { ($0, OrcaSourceHealth(ok: false)) })
    )
}
