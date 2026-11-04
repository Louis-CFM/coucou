import Foundation

/// Errors encountered during MCP protocol communication.
enum MCPClientError: Error, Equatable, Sendable {
    case processStartFailed(String)
    case timeout(String)
    case invalidResponse(String)
    case serverError(String)
    case terminated
}

/// Where an imported MCP server configuration was found on this Mac.
enum MCPServerSource: String, Codable, Equatable, Sendable, CaseIterable {
    case claudeDesktop = "claude-desktop"
    case claudeCode    = "claude-code"
    case cursor        = "cursor"
    case vscode        = "vscode"
    case windsurf      = "windsurf"
    case opencode      = "opencode"
    case manual        = "manual"

    var displayName: String {
        switch self {
        case .claudeDesktop: return "Claude Desktop"
        case .claudeCode:    return "Claude Code"
        case .cursor:        return "Cursor"
        case .vscode:        return "VS Code"
        case .windsurf:      return "Windsurf"
        case .opencode:      return "OpenCode"
        case .manual:        return "Manual"
        }
    }
}

/// Transport protocol used to communicate with an MCP server.
enum MCPTransport: Codable, Equatable, Sendable {
    case stdio(command: String, args: [String], env: [String: String])
    case http(url: String, headers: [String: String])

    private enum CodingKeys: String, CodingKey {
        case type, command, args, env, url, headers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        if type == "stdio" {
            let command = try container.decode(String.self, forKey: .command)
            let args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
            let env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
            self = .stdio(command: command, args: args, env: env)
        } else if type == "http" {
            let url = try container.decode(String.self, forKey: .url)
            let headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
            self = .http(url: url, headers: headers)
        } else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown MCP transport: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .stdio(let command, let args, let env):
            try container.encode("stdio", forKey: .type)
            try container.encode(command, forKey: .command)
            try container.encode(args, forKey: .args)
            try container.encode(env, forKey: .env)
        case .http(let url, let headers):
            try container.encode("http", forKey: .type)
            try container.encode(url, forKey: .url)
            try container.encode(headers, forKey: .headers)
        }
    }
}

/// A configured MCP server discovered or added in Coucou.
struct MCPServerConfig: Codable, Identifiable, Equatable, Sendable {
    /// Stable unique slug (e.g. "postgres", "github-2").
    let id: String
    /// Human-friendly display name.
    var name: String
    /// Developer tools where this server was discovered.
    var sources: [MCPServerSource]
    /// How Coucou communicates with this server (subprocess stdio or remote HTTP).
    var transport: MCPTransport
    /// Whether this server is active and exposed to the chat.
    var isEnabled: Bool
    /// If true, only read-only tools can run automatically; mutating tools ask in the Island.
    var isReadOnly: Bool
    /// Informational notes (e.g. environment variable requirements, warnings).
    var notes: [String]

    init(id: String,
         name: String,
         sources: [MCPServerSource],
         transport: MCPTransport,
         isEnabled: Bool = true,
         isReadOnly: Bool = true,
         notes: [String] = []) {
        self.id = id
        self.name = name
        self.sources = sources
        self.transport = transport
        self.isEnabled = isEnabled
        self.isReadOnly = isReadOnly
        self.notes = notes
    }

    /// Short human-readable summary for settings lists (with credentials masked).
    var summary: String {
        switch transport {
        case .stdio(let command, let args, _):
            let shortCommand = (command as NSString).lastPathComponent
            let visibleArgs = args.prefix(3).map { MCPScanner.maskPotentialSecret($0) }
            return ([shortCommand] + visibleArgs).joined(separator: " ")
        case .http(let url, _):
            return MCPScanner.maskURL(url)
        }
    }
}

// MARK: - Dynamic JSON Value

/// Type-erased JSON-compatible value that conforms to Codable, Equatable, and Sendable.
enum AnyCodable: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case dictionary([String: AnyCodable])
    case array([AnyCodable])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([AnyCodable].self) {
            self = .array(arr)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            self = .dictionary(dict)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown AnyCodable value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .dictionary(let dict): try container.encode(dict)
        case .array(let arr): try container.encode(arr)
        case .null: try container.encodeNil()
        }
    }

    /// Converts raw Foundation JSON object into AnyCodable
    static func from(any: Any) -> AnyCodable {
        if let s = any as? String { return .string(s) }
        if let b = any as? Bool { return .bool(b) }
        if let i = any as? Int { return .int(i) }
        if let d = any as? Double { return .double(d) }
        if let dict = any as? [String: Any] {
            return .dictionary(dict.mapValues { from(any: $0) })
        }
        if let arr = any as? [Any] {
            return .array(arr.map { from(any: $0) })
        }
        return .null
    }

    /// Converts back to raw Foundation object for serialization
    var rawValue: Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .dictionary(let d): return d.mapValues { $0.rawValue }
        case .array(let a): return a.map { $0.rawValue }
        case .null: return NSNull()
        }
    }
}

// MARK: - Tool Definitions & Execution

/// An individual tool exposed by an MCP server.
struct MCPTool: Codable, Identifiable, Equatable, Sendable {
    /// Combined identifier for function dispatch: "mcp__<serverID>__<name>".
    var id: String { "mcp__\(serverID)__\(name)" }
    /// Canonical tool name as declared by the MCP server (e.g. "read_file", "query_database").
    let name: String
    /// Slug of the server offering this tool.
    let serverID: String
    /// Display name of the server (e.g. "PostgreSQL").
    let serverName: String
    /// Documentation/description for the tool.
    let description: String
    /// JSON Schema describing input arguments.
    let inputSchema: [String: AnyCodable]
    /// Whether this tool is non-mutating (safe to execute without prompt).
    let isReadOnly: Bool
}

/// An execution request directed to an MCP tool.
struct MCPToolCall: Codable, Equatable, Sendable {
    let callID: String
    let serverID: String
    let toolName: String
    let arguments: [String: AnyCodable]
}

/// The result returned from an MCP tool call.
struct MCPToolResult: Codable, Equatable, Sendable {
    let content: String
    let isError: Bool
}

/// Common interface for interacting with an MCP server regardless of transport.
protocol MCPClientProtocol: Sendable {
    var config: MCPServerConfig { get }
    func initializeAndListTools(timeout: TimeInterval) async throws -> [MCPTool]
    func callTool(name: String, arguments: [String: AnyCodable], timeout: TimeInterval) async throws -> MCPToolResult
}

extension MCPClientProtocol {
    func initializeAndListTools() async throws -> [MCPTool] {
        try await initializeAndListTools(timeout: 10)
    }

    func callTool(name: String, arguments: [String: AnyCodable]) async throws -> MCPToolResult {
        try await callTool(name: name, arguments: arguments, timeout: 60)
    }
}
