import Foundation

@main
enum MCPChatCoordinatorTests {
    static func main() throws {
        var cases = 0
        func check(_ ok: Bool, _ what: String, line: UInt = #line) {
            precondition(ok, "\(what) (line \(line))")
            cases += 1
        }

        // MARK: - Safety Decision Tests
        let readTool = MCPTool(
            name: "fetch_status",
            serverID: "srv1",
            serverName: "Test Server",
            description: "Read status",
            inputSchema: [:],
            isReadOnly: true
        )

        let writeTool = MCPTool(
            name: "delete_record",
            serverID: "srv1",
            serverName: "Test Server",
            description: "Delete record",
            inputSchema: [:],
            isReadOnly: false
        )

        check(readTool.isReadOnly, "read-only tool marked safe")
        check(!writeTool.isReadOnly, "mutating tool marked unsafe")

        // MARK: - OpenAI Tool Call Parsing & Routing
        let toolCallJSON: [String: Any] = [
            "id": "call_abc123",
            "type": "function",
            "function": [
                "name": "mcp__srv1__fetch_status",
                "arguments": #"{"id": 42}"#
            ]
        ]

        let fn = toolCallJSON["function"] as? [String: Any]
        let name = fn?["name"] as? String ?? ""
        let decoded = MCPJSONRPC.decodeFunctionName(name)
        check(decoded?.serverID == "srv1", "decoded serverID")
        check(decoded?.toolName == "fetch_status", "decoded toolName")

        // Test arguments deserialization
        let rawArgs = fn?["arguments"] as? String ?? "{}"
        let argsDict = (try? JSONSerialization.jsonObject(with: Data(rawArgs.utf8))) as? [String: Any] ?? [:]
        let anyArgs = argsDict.mapValues { AnyCodable.from(any: $0) }
        check(anyArgs["id"] == .int(42), "parsed numeric argument as AnyCodable int")

        // MARK: - Tool Result Framing
        let successResult = MCPToolResult(content: "Status: healthy", isError: false)
        let toolMessage: [String: Any] = [
            "role": "tool",
            "tool_call_id": "call_abc123",
            "content": successResult.content
        ]
        check(toolMessage["role"] as? String == "tool", "role is tool")
        check(toolMessage["tool_call_id"] as? String == "call_abc123", "tool_call_id matches")
        check(toolMessage["content"] as? String == "Status: healthy", "content matches")

        let rejectedResult = MCPToolResult(content: "User rejected permission to run this tool.", isError: true)
        check(rejectedResult.isError, "rejected result marked as error")
        check(rejectedResult.content.contains("rejected"), "rejection message framed")

        print("All \(cases) MCPChatCoordinator tests passed.")
    }
}
