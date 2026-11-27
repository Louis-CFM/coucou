import Foundation

/// Central registry managing discovered tools and dispatching execution across active MCP servers.
@MainActor
final class MCPToolRegistry: ObservableObject {

    static let shared = MCPToolRegistry()

    @Published private(set) var availableTools: [MCPTool] = []
    @Published private(set) var isRefreshing = false

    private var clients: [String: any MCPClientProtocol] = [:]

    private init() {}

    private func makeClient(for config: MCPServerConfig) -> any MCPClientProtocol {
        switch config.transport {
        case .stdio:
            return MCPStdioClient(config: config)
        case .http:
            return MCPHTTPClient(config: config)
        }
    }

    // MARK: - Tool Discovery & Cache

    /// Refreshes tool definitions for all currently enabled servers.
    func refreshTools(from configs: [MCPServerConfig]) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let enabledConfigs = configs.filter(\.isEnabled)
        var allTools: [MCPTool] = []

        // Remove cached clients for servers that were disabled or removed
        let activeIDs = Set(enabledConfigs.map(\.id))
        clients = clients.filter { activeIDs.contains($0.key) }

        for config in enabledConfigs {
            // Re-create client if config changed (e.g. arguments, env, transport)
            let client: any MCPClientProtocol
            if let existing = clients[config.id], existing.config == config {
                client = existing
            } else {
                client = makeClient(for: config)
                clients[config.id] = client
            }

            do {
                let tools = try await client.initializeAndListTools(timeout: 10)
                allTools.append(contentsOf: tools)
            } catch {
                // If a server fails or isn't running, log and skip without breaking the other tools
                allTools.append(contentsOf: [])
            }
        }

        self.availableTools = allTools
    }

    // MARK: - OpenAI Payload Formatting

    /// Serializes all active tools into the standard OpenAI `tools` array for chat completions.
    func openAIToolsPayload() -> [[String: Any]] {
        return availableTools.map { MCPJSONRPC.openAIToolDefinition(for: $0) }
    }

    // MARK: - Dispatch

    /// Finds a tool by its qualified ID ("mcp__<serverID>__<toolName>")
    func tool(forID id: String) -> MCPTool? {
        return availableTools.first { $0.id == id }
    }

    /// Dispatches a tool call to the owning MCP client.
    func execute(qualifiedToolID: String, arguments: [String: AnyCodable]) async -> MCPToolResult {
        guard let tool = tool(forID: qualifiedToolID) else {
            return MCPToolResult(content: "Unknown MCP tool: \(qualifiedToolID)", isError: true)
        }

        guard let client = clients[tool.serverID] else {
            return MCPToolResult(content: "MCP server \(tool.serverName) is not currently connected.", isError: true)
        }

        do {
            return try await client.callTool(name: tool.name, arguments: arguments)
        } catch {
            return MCPToolResult(content: "Error executing \(tool.name): \(error.localizedDescription)", isError: true)
        }
    }
}
