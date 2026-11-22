import Foundation

// A task started from the iPhone with the agent of your choice, in a folder your Mac worked in
// lately (InstructionRunner, GitHub build of Coucou). The Mac publishes what it can run
// (`MacAgents`), the iPhone sends an `Instruction` with an agent and a folder, and the Mac writes
// how it ended (`TaskResult`). Folders only ever come from the Mac's own list.

/// The agents the iPhone can start a task with.
enum PhoneAgent: String, Codable, CaseIterable, Sendable {
    case claude, codex, cursor, antigravity

    var name: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor Agent"
        case .antigravity: "Antigravity"
        }
    }

    /// The pill it takes its color from.
    var pillId: String {
        switch self {
        case .claude: "integration_claude"
        case .codex: "agent_codex"
        case .cursor: "agent_cursor"
        case .antigravity: "agent_antigravity"
        }
    }

    /// Claude Code asks for each command on the iPhone (Coucou's hooks); the others follow their
    /// own settings on the Mac, as when they run without a window.
    var asksOnPhone: Bool { self == .claude }
}

/// What this Mac can run for the iPhone.
struct MacAgents: Codable, Equatable, Sendable {
    struct Project: Codable, Equatable, Hashable, Sendable {
        var name: String
        var path: String
    }

    var agents: [PhoneAgent]
    var projects: [Project]
    var updatedAt: Date

    static let recordType = "MacAgents"
    static let recordName = "mac-agents"

    func sameContent(as other: MacAgents) -> Bool { agents == other.agents && projects == other.projects }
}

/// How a task started from the iPhone ended.
struct TaskResult: Codable, Equatable, Sendable {
    var id: String
    var agent: PhoneAgent
    var project: String
    var ok: Bool
    /// The end of what the agent printed (its last answer, or why it stopped).
    var summary: String
    var endedAt: Date

    static let recordType = "TaskResult"
}
