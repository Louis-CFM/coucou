import Foundation

// MARK: - ACP Agent Configuration

/// A user-configured ACP agent (launched as a subprocess, communicates via JSON-RPC over stdio).
struct AcpAgentConfig: Codable, Identifiable, Equatable {
    var id: String          // stable UUID
    var name: String        // display name ("Claude Agent", "Codex CLI", …)
    var command: String     // absolute path to the executable
    var args: String        // space-separated args (simpler than [String] for UserDefaults)
    var env: String         // KEY=VALUE pairs, one per line
    var color: String       // hex color for the pill/chip
    var model: String       // model ID to select on session/new (e.g. "catpaw-relay/gpt-6-sol")

    init(id: String = UUID().uuidString, name: String, command: String,
         args: String = "", env: String = "", color: String = "#818CF8",
         model: String = "") {
        self.id = id
        self.name = name
        self.command = command
        self.args = args
        self.env = env
        self.color = color
        self.model = model
    }

    /// Parsed argument list (splits on whitespace, respects basic quoting).
    var argList: [String] {
        args.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Parsed environment variables.
    var envDict: [String: String] {
        var out: [String: String] = [:]
        for line in env.components(separatedBy: .newlines) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            out[String(parts[0])] = String(parts[1])
        }
        return out
    }
}

// MARK: - ACP Config Store

enum AcpConfigStore {
    private static let key = "acpAgentConfigs"

    static func load() -> [AcpAgentConfig] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let configs = try? JSONDecoder().decode([AcpAgentConfig].self, from: data) else { return [] }
        return configs
    }

    static func save(_ configs: [AcpAgentConfig]) {
        guard let data = try? JSONEncoder().encode(configs) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func add(_ config: AcpAgentConfig) {
        var configs = load()
        configs.append(config)
        save(configs)
    }

    static func remove(id: String) {
        var configs = load()
        configs.removeAll { $0.id == id }
        save(configs)
    }

    static func update(_ config: AcpAgentConfig) {
        var configs = load()
        if let idx = configs.firstIndex(where: { $0.id == config.id }) {
            configs[idx] = config
        }
        save(configs)
    }

    // MARK: - Default agents

    /// Pre-seeded default ACP agent configurations (e.g. Pi via pi-acp).
    /// These are offered as one-click additions in the settings UI.
    /// Note: `command` uses a bare name; AcpClient.resolveCommand() expands it from $PATH.
    static let defaults: [AcpAgentConfig] = [
        AcpAgentConfig(
            id: "acp_default_pi",
            name: "Pi",
            command: "npx",
            args: "pi-acp",
            env: "",
            color: "#FACC15",
            model: "catpaw-relay/gpt-6-sol"
        ),
    ]

    /// Ensures default agents that aren't already present are available
    /// as quick-add options. Does NOT auto-add them — just makes them
    /// visible in Settings → ACP Agents.
    static func defaultNotYetAdded() -> [AcpAgentConfig] {
        let existing = load()
        return defaults.filter { def in !existing.contains(where: { $0.id == def.id }) }
    }
}

// MARK: - ACP JSON-RPC Client (stdio transport)

/// Manages a single ACP agent subprocess: initialize → session/new → prompt turns.
/// Communication is newline-delimited JSON-RPC 2.0 over the process's stdin/stdout.
@MainActor
final class AcpClient: @unchecked Sendable {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    private var nextId: Int = 0
    private var pendingRequests: [Int: (CheckedContinuation<[String: Any], Error>)] = [:]
    private var sessionId: String?
    private var agentInfo: AgentInfo?

    private let readQueue = DispatchQueue(label: "com.coucou.acp-read")
    /// Timeout for JSON-RPC requests (seconds).
    private let requestTimeout: TimeInterval = 120

    struct AgentInfo {
        let name: String
        let title: String?
        let version: String?
    }

    // MARK: - Path resolution

    /// Searches $PATH for an executable, returning the absolute path or nil.
    private static func resolveOnPath(_ command: String) -> String? {
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in pathEnv.components(separatedBy: ":") {
            let candidate = (dir as NSString).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Lifecycle

    /// Launches the agent subprocess and performs the ACP initialize handshake.
    func connect(config: AcpAgentConfig, cwd: String) async throws {
        disconnect()

        let proc = Process()
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()

        // Resolve command: if it's a bare name (no /), search $PATH;
        // otherwise use as-is (absolute or relative path).
        let resolvedCommand: String
        if config.command.contains("/") {
            resolvedCommand = config.command
        } else {
            resolvedCommand = Self.resolveOnPath(config.command) ?? config.command
        }

        proc.executableURL = URL(fileURLWithPath: resolvedCommand)
        proc.arguments = config.argList
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // Merge agent env + parent env
        var env = ProcessInfo.processInfo.environment
        for (k, v) in config.envDict { env[k] = v }
        proc.environment = env

        self.process = proc
        self.stdinPipe = inPipe
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe
        self.nextId = 0
        self.pendingRequests = [:]
        self.sessionId = nil

        try proc.run()

        // Start reading stdout on a background queue
        // Capture the read handle before entering background queue.
        let outHandle = outPipe.fileHandleForReading
        readQueue.async { [weak self] in
            var buf = Data()
            while true {
                let data = outHandle.availableData
                if data.isEmpty { break }
                buf.append(data)
                // Scan for complete newline-delimited lines
                var start = 0
                for i in 0..<buf.count where buf[i] == UInt8(ascii: "\n") {
                    if i > start {
                        let lineData = buf[start..<i]
                        DispatchQueue.main.async { [weak self] in
                            self?.handleLine(lineData)
                        }
                    }
                    start = i + 1
                }
                buf = Data(buf[start..<buf.count])
            }
            // EOF: cancel any pending requests
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for (_, cont) in self.pendingRequests {
                    cont.resume(throwing: AcpError.disconnected)
                }
                self.pendingRequests = [:]
            }
        }

        // Drain stderr on a background queue to prevent the pipe buffer from
        // filling up and blocking the agent process.
        let errHandle = errPipe.fileHandleForReading
        readQueue.async {
            while true {
                let data = errHandle.availableData
                if data.isEmpty { break }
                // Log first line of stderr for debugging; swallow the rest.
                if let line = String(data: data, encoding: .utf8), !line.isEmpty {
                    NSLog("[ACP stderr] %s", String(line.prefix(200)))
                }
            }
        }

        // ACP initialize
        let initResult = try await sendRequest(method: "initialize", params: [
            "protocolVersion": 1,
            "clientCapabilities": [
                "fs": ["readTextFile": true, "writeTextFile": true],
                "terminal": true,
            ],
            "clientInfo": [
                "name": "coucou",
                "title": "Coucou",
                "version": "0.3.0",
            ],
        ])

        let info = initResult["agentInfo"] as? [String: Any] ?? [:]
        self.agentInfo = AgentInfo(
            name: info["name"] as? String ?? config.name,
            title: info["title"] as? String,
            version: info["version"] as? String
        )

        // Create a new session (pass model config if specified)
        var sessionParams: [String: Any] = [
            "cwd": cwd,
            "mcpServers": [],
        ]
        if !config.model.isEmpty {
            sessionParams["config"] = ["model": config.model]
        }
        let sessResult = try await sendRequest(method: "session/new", params: sessionParams)
        self.sessionId = sessResult["sessionId"] as? String

        // If the agent returned configOptions with a model list and our requested
        // model was not applied, try session/config (best-effort; older agents
        // may not support it).
        if !config.model.isEmpty, let sid = self.sessionId {
            let currentModel = (sessResult["models"] as? [String: Any])?["currentModelId"] as? String ?? ""
            if currentModel != config.model {
                _ = try? await sendRequest(method: "session/config", params: [
                    "sessionId": sid,
                    "config": ["model": config.model],
                ])
                // Ignore failure — the agent will use whatever model it has.
            }
        }
    }

    /// Terminates the agent subprocess.
    func disconnect() {
        for (_, cont) in pendingRequests {
            cont.resume(throwing: AcpError.disconnected)
        }
        pendingRequests = [:]
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        if let proc = process, proc.isRunning {
            proc.interrupt()
            // Give it a moment, then force-terminate
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if proc.isRunning { proc.terminate() }
            }
        }
        process = nil
        sessionId = nil
        agentInfo = nil
    }

    var isConnected: Bool { process?.isRunning == true }
    var agentName: String { agentInfo?.title ?? agentInfo?.name ?? "Agent" }

    // MARK: - Prompt

    /// Sends a user prompt and streams the agent's response via the callback.
    ///
    /// - Parameters:
    ///   - message: The user's text message.
    ///   - onChunk: Called on the main actor for each `agent_message_chunk`.
    ///   - onToolCall: Called on the main actor when a tool_call starts.
    ///   - onToolUpdate: Called on the main actor when a tool_call status changes.
    /// - Returns: The final stop reason.
    func prompt(
        message: String,
        onChunk: @MainActor @escaping (String) -> Void,
        onToolCall: @MainActor @escaping (String, String) -> Void = { _, _ in },
        onToolUpdate: @MainActor @escaping (String, String) -> Void = { _, _ in }
    ) async throws -> String {
        guard let sid = sessionId else { throw AcpError.noSession }

        let params: [String: Any] = [
            "sessionId": sid,
            "prompt": [
                ["type": "text", "text": message]
            ],
        ]

        // We use a special path: send the request, but don't await the continuation
        // for the final response until after we've processed all notifications.
        // The notifications arrive as side-effect reads in readLoop and are
        // dispatched here via the notification handlers.

        self.chunkHandler = onChunk
        self.toolCallHandler = onToolCall
        self.toolUpdateHandler = onToolUpdate
        self.receivedFirstChunk = false

        let result = try await sendRequest(method: "session/prompt", params: params)

        self.chunkHandler = nil
        self.toolCallHandler = nil
        self.toolUpdateHandler = nil

        return result["stopReason"] as? String ?? "end_turn"
    }

    /// Cancels the current prompt turn.
    func cancel() {
        guard let sid = sessionId else { return }
        let notification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "session/cancel",
            "params": ["sessionId": sid],
        ]
        sendRaw(notification)
    }

    private var receivedFirstChunk = false

    // MARK: - Notification handlers (set during prompt)

    private var chunkHandler: (@MainActor (String) -> Void)?
    private var toolCallHandler: (@MainActor (String, String) -> Void)?
    private var toolUpdateHandler: (@MainActor (String, String) -> Void)?

    // MARK: - JSON-RPC transport

    private func sendRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
        guard let _ = stdinPipe, process?.isRunning == true else {
            throw AcpError.disconnected
        }
        let id = nextId
        nextId += 1

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]
        sendRaw(request)

        return try await withCheckedThrowingContinuation { cont in
            pendingRequests[id] = cont
            // Timeout: if no response comes within requestTimeout, resume with error
            readQueue.asyncAfter(deadline: .now() + requestTimeout) { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let cont = self.pendingRequests.removeValue(forKey: id) {
                        cont.resume(throwing: AcpError.agentError("Request timed out: \(method)"))
                    }
                }
            }
        }
    }

    private func sendRaw(_ object: [String: Any]) {
        guard let pipe = stdinPipe,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let str = String(data: data, encoding: .utf8) else { return }
        let line = str + "\n"
        guard let lineData = line.data(using: .utf8) else { return }
        pipe.fileHandleForWriting.write(lineData)
    }

    // MARK: - Line handler (called on MainActor from read loop)

    private func handleLine(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        // Response to a request
        if let id = json["id"] as? Int {
            if let cont = pendingRequests.removeValue(forKey: id) {
                if let error = json["error"] as? [String: Any] {
                    let msg = error["message"] as? String ?? "Unknown ACP error"
                    cont.resume(throwing: AcpError.agentError(msg))
                } else if let result = json["result"] as? [String: Any] {
                    cont.resume(returning: result)
                } else {
                    // JSON-RPC allows result to be null/missing for notifications
                    cont.resume(returning: [:])
                }
            }
            return
        }

        // Notification from agent (no id)
        guard let method = json["method"] as? String else { return }
        let params = json["params"] as? [String: Any] ?? [:]

        switch method {
        case "session/update":
            handleSessionUpdate(params)
        default:
            break  // ignore unknown notifications for now
        }
    }

    // MARK: - Session update dispatch

    private func handleSessionUpdate(_ params: [String: Any]) {
        guard let update = params["update"] as? [String: Any],
              let kind = update["sessionUpdate"] as? String else { return }

        switch kind {
        case "agent_message_chunk":
            if let content = update["content"] as? [String: Any],
               let text = content["text"] as? String {
                // Skip the first chunk if it looks like a system/session info dump
                // (Pi pushes its startup info as the first message_chunk, >2KB,
                //  starting with "pi v" or similar). Real assistant replies are
                //  typically short incremental chunks.
                if !receivedFirstChunk {
                    receivedFirstChunk = true
                    if text.count > 2000 && (text.hasPrefix("pi v") || text.hasPrefix("pi ")) {
                        break  // skip system info chunk
                    }
                }
                chunkHandler?(text)
            }
        case "tool_call":
            let toolCallId = update["toolCallId"] as? String ?? ""
            let title = update["title"] as? String ?? "Tool"
            toolCallHandler?(toolCallId, title)
        case "tool_call_update":
            let toolCallId = update["toolCallId"] as? String ?? ""
            let status = update["status"] as? String ?? ""
            toolUpdateHandler?(toolCallId, status)
        default:
            break  // plan, user_message_chunk, usage_update, etc. — silently ignore for now
        }
    }
}

// MARK: - ACP Errors

enum AcpError: Error, LocalizedError {
    case disconnected
    case noSession
    case agentError(String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .disconnected:   return "Agent disconnected."
        case .noSession:      return "No active ACP session."
        case .agentError(let msg): return msg
        case .launchFailed(let msg): return "Failed to launch agent: \(msg)"
        }
    }
}
