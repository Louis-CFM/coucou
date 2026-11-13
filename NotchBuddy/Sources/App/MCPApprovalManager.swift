import Foundation

/// Asks on the notch before the chat runs a tool of an MCP server that changes things.
/// The request waits in HookServer's approval line like any agent's: first in, first shown,
/// never replacing another request. It runs only on an Allow clicked before its deadline;
/// Deny, a full line, the timeout or a dropped card are refusals.
@MainActor
final class MCPApprovalManager {

    static let shared = MCPApprovalManager()

    /// What of the arguments the card shows.
    static let maxShownArguments = 300

    private init() {}

    func requestApproval(tool: MCPTool, arguments: [String: AnyCodable]) async -> Bool {
        await HookServer.shared.enqueueMCPApproval(tool: "\(tool.serverName): \(tool.name)",
                                                   command: Self.shownArguments(arguments),
                                                   inputKey: tool.id)
    }

    /// The arguments on one line, keys sorted, cut to what the card can show.
    static func shownArguments(_ arguments: [String: AnyCodable]) -> String {
        let text = arguments.keys.sorted()
            .map { key in "\(key): \(arguments[key].map { value in "\(value.rawValue)" } ?? "")" }
            .joined(separator: ", ")
        guard text.count > maxShownArguments else { return text }
        return String(text.prefix(maxShownArguments)) + "…"
    }
}
