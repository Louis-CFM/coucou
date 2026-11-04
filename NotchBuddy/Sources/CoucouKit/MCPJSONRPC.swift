import Foundation

/// JSON-RPC 2.0 protocol layer for MCP communication and OpenAI function schema bridging.
enum MCPJSONRPC {

    private static let safeReadPrefixes = ["get_", "list_", "read_", "search_", "fetch_", "check_", "describe_", "view_", "show_", "find_"]
    private static let mutatingKeywords = ["write", "delete", "remove", "drop", "send", "post", "update", "create", "insert", "execute", "run", "edit", "patch", "modify"]

    // MARK: - Message Building

    /// Builds a formatted JSON-RPC 2.0 request line (newline-terminated).
    static func makeRequest(id: Int, method: String, params: [String: Any]? = nil) -> String {
        var obj: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method
        ]
        if let params {
            obj["params"] = params
        }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)"}"# + "\n"
        }
        return text + "\n"
    }

    /// Builds a formatted JSON-RPC 2.0 notification line (newline-terminated).
    static func makeNotification(method: String, params: [String: Any]? = nil) -> String {
        var obj: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method
        ]
        if let params {
            obj["params"] = params
        }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"jsonrpc":"2.0","method":"\#(method)"}"# + "\n"
        }
        return text + "\n"
    }

    /// Initial MCP handshake request.
    static func initializeRequest(id: Int, clientName: String = "Coucou", version: String = "0.3.0") -> String {
        let params: [String: Any] = [
            "protocolVersion": "2024-11-05",
            "capabilities": [
                "tools": [:]
            ],
            "clientInfo": [
                "name": clientName,
                "version": version
            ]
        ]
        return makeRequest(id: id, method: "initialize", params: params)
    }

    /// Confirms MCP initialization completion.
    static func initializedNotification() -> String {
        return makeNotification(method: "notifications/initialized")
    }

    /// Requests available tools from the server.
    static func toolsListRequest(id: Int) -> String {
        return makeRequest(id: id, method: "tools/list")
    }

    /// Invokes a specific tool on the server with arguments.
    static func toolCallRequest(id: Int, name: String, arguments: [String: AnyCodable]) -> String {
        let rawArgs = arguments.mapValues { $0.rawValue }
        let params: [String: Any] = [
            "name": name,
            "arguments": rawArgs
        ]
        return makeRequest(id: id, method: "tools/call", params: params)
    }

    // MARK: - Parsing

    /// Decodes a line of JSON-RPC response.
    static func parseResponse(line: String) -> (id: Int?, result: [String: Any]?, error: [String: Any]?)? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let id = json["id"] as? Int
        let result = json["result"] as? [String: Any]
        let error = json["error"] as? [String: Any]

        guard result != nil || error != nil else { return nil }
        return (id, result, error)
    }

    /// Extracts MCPTool definitions from a `tools/list` result dictionary.
    static func parseToolsList(result: [String: Any], serverID: String, serverName: String) -> [MCPTool] {
        guard let toolsArray = result["tools"] as? [[String: Any]] else { return [] }
        var tools: [MCPTool] = []

        for rawTool in toolsArray {
            guard let name = rawTool["name"] as? String else { continue }
            let desc = (rawTool["description"] as? String) ?? ""
            let readOnlyHint = rawTool["readOnlyHint"] as? Bool
            let isReadOnly = classifyToolSafety(name: name, readOnlyHint: readOnlyHint)

            var inputSchema: [String: AnyCodable] = [:]
            if let schemaDict = rawTool["inputSchema"] as? [String: Any] {
                inputSchema = schemaDict.mapValues { AnyCodable.from(any: $0) }
            }

            tools.append(MCPTool(
                name: name,
                serverID: serverID,
                serverName: serverName,
                description: desc,
                inputSchema: inputSchema,
                isReadOnly: isReadOnly
            ))
        }
        return tools
    }

    /// Extracts content or failure message from a `tools/call` result dictionary.
    static func parseToolCallResult(result: [String: Any]?, error: [String: Any]?) -> MCPToolResult {
        if let error {
            let msg = (error["message"] as? String) ?? "Tool call failed."
            return MCPToolResult(content: msg, isError: true)
        }

        guard let result else {
            return MCPToolResult(content: "Empty response from tool.", isError: true)
        }

        let isError = (result["isError"] as? Bool) ?? false

        if let contents = result["content"] as? [[String: Any]] {
            let texts = contents.compactMap { item -> String? in
                if let text = item["text"] as? String { return text }
                return nil
            }
            if !texts.isEmpty {
                return MCPToolResult(content: texts.joined(separator: "\n"), isError: isError)
            }
        }

        // Fallback: entire result serialized as JSON string
        if let data = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted),
           let str = String(data: data, encoding: .utf8) {
            return MCPToolResult(content: str, isError: isError)
        }

        return MCPToolResult(content: "Success", isError: isError)
    }

    // MARK: - Safety Classification (Fail-Closed)

    /// Decides whether a tool can execute without prompt based on hints and heuristics.
    static func classifyToolSafety(name: String, readOnlyHint: Bool?) -> Bool {
        if let hint = readOnlyHint {
            return hint
        }
        let lower = name.lowercased()
        if mutatingKeywords.contains(where: { lower.contains($0) }) {
            return false
        }
        if safeReadPrefixes.contains(where: { lower.hasPrefix($0) }) {
            return true
        }
        // Fail-closed default: if uncertain, assume mutating and ask for approval.
        return false
    }

    // MARK: - OpenAI Bridge

    /// Encodes tool identity into an OpenAI function name: "mcp__<serverID>__<toolName>".
    static func encodeFunctionName(serverID: String, toolName: String) -> String {
        return "mcp__\(serverID)__\(toolName)"
    }

    /// Decodes an OpenAI function call name back into server slug and tool name.
    static func decodeFunctionName(_ name: String) -> (serverID: String, toolName: String)? {
        guard name.hasPrefix("mcp__") else { return nil }
        let trimmed = String(name.dropFirst(5))
        let components = trimmed.components(separatedBy: "__")
        guard components.count >= 2 else { return nil }
        let serverID = components[0]
        let toolName = components.dropFirst().joined(separator: "__")
        return (serverID, toolName)
    }

    /// Formats an MCPTool as an OpenAI tool object for chat completion payloads.
    static func openAIToolDefinition(for tool: MCPTool) -> [String: Any] {
        var params: [String: Any] = [
            "type": "object",
            "properties": [:]
        ]
        if !tool.inputSchema.isEmpty {
            params = tool.inputSchema.mapValues { $0.rawValue }
        }

        let desc = tool.description.isEmpty
            ? "Provided by \(tool.serverName)"
            : "[\(tool.serverName)] \(tool.description)"

        return [
            "type": "function",
            "function": [
                "name": tool.id,
                "description": desc,
                "parameters": params
            ]
        ]
    }
}
