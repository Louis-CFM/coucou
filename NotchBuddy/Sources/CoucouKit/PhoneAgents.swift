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
    /// The agent's last answer, or why it stopped.
    var summary: String
    var endedAt: Date
    /// What Claude Code wanted to do and was turned down for, since nobody could say yes
    /// while it ran (a run without a window). The iPhone can allow exactly these and continue.
    var needs: [TaskPermission]? = nil

    static let recordType = "TaskResult"
}

/// One action an agent needed your OK for: the tool and what it would have touched.
struct TaskPermission: Codable, Equatable, Hashable, Sendable {
    var tool: String
    /// The command, the file or the address, as the agent asked for it.
    var detail: String
}

/// Claude Code sessions this Mac started for the iPhone: they run without a window, so the
/// notch offers no "Open terminal" for them.
@MainActor
enum PhoneTaskSessions {
    static var ids: Set<String> = []
}
