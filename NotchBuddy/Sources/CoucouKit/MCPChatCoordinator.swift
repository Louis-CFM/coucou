import Foundation

/// Coordinates tool calling for the chat interface, mediating between LLM requests,
/// the MCPToolRegistry, and the Notch human approval workflow.
@MainActor
final class MCPChatCoordinator {

    static let shared = MCPChatCoordinator()

    private init() {}

    /// Executes an MCP tool, prompting for approval in the Notch if mutating.
    func executeWithApproval(tool: MCPTool, arguments: [String: AnyCodable]) async -> MCPToolResult {
        let isApproved: Bool
        if tool.isReadOnly {
            isApproved = true
        } else {
            #if os(macOS)
            isApproved = await MCPApprovalManager.shared.requestApproval(tool: tool, arguments: arguments)
            #else
            isApproved = true
            #endif
        }

        guard isApproved else {
            return MCPToolResult(content: "User rejected permission to run this tool.", isError: true)
        }

        return await MCPToolRegistry.shared.execute(qualifiedToolID: tool.id, arguments: arguments)
    }

    /// Processes an array of OpenAI-compatible tool_calls and executes each tool.
    func handleToolCalls(_ toolCalls: [[String: Any]]) async -> [[String: Any]] {
        var toolResponses: [[String: Any]] = []

        for call in toolCalls {
            guard let callID = call["id"] as? String,
                  let fn = call["function"] as? [String: Any],
                  let fnName = fn["name"] as? String else { continue }

            let rawArgs = (fn["arguments"] as? String) ?? "{}"
            let parsedArgsDict = (try? JSONSerialization.jsonObject(with: Data(rawArgs.utf8))) as? [String: Any] ?? [:]
            let anyArgs = parsedArgsDict.mapValues { AnyCodable.from(any: $0) }

            guard let tool = MCPToolRegistry.shared.tool(forID: fnName) else {
                toolResponses.append([
                    "role": "tool",
                    "tool_call_id": callID,
                    "content": "Tool \(fnName) not found."
                ])
                continue
            }

            let result = await executeWithApproval(tool: tool, arguments: anyArgs)
            toolResponses.append([
                "role": "tool",
                "tool_call_id": callID,
                "content": result.content
            ])
        }

        return toolResponses
    }
}
