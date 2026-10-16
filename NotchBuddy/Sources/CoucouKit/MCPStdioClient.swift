import Foundation

#if !APPSTORE && os(macOS)
/// Actor managing the stdio lifecycle of a single MCP server subprocess.
actor MCPStdioClient: MCPClientProtocol {

    let config: MCPServerConfig
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var nextRequestID = 1
    private var isInitialized = false

    init(config: MCPServerConfig) {
        self.config = config
    }

    deinit {
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
    }

    // MARK: - Lifecycle

    /// Starts the subprocess if not already running.
    func start() throws {
        guard process == nil || process?.isRunning == false else { return }

        guard case .stdio(let command, let args, let env) = config.transport else {
            throw MCPClientError.processStartFailed("Config is not stdio transport.")
        }

        let proc = Process()
        let resolvedCommand = resolveExecutable(command)
        proc.executableURL = URL(fileURLWithPath: resolvedCommand)
        proc.arguments = args

        let tmpFolder = FileManager.default.temporaryDirectory.appendingPathComponent("coucou-mcp-\(config.id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpFolder, withIntermediateDirectories: true)
        proc.currentDirectoryURL = tmpFolder

        var procEnv = ProcessInfo.processInfo.environment
        let basePATH = [URL(fileURLWithPath: resolvedCommand).deletingLastPathComponent().path,
                        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                        "\(NSHomeDirectory())/.nvm/versions/node",
                        "\(NSHomeDirectory())/.local/bin",
                        procEnv["PATH"] ?? ""].joined(separator: ":")
        procEnv["PATH"] = basePATH
        procEnv.merge(env) { _, new in new }
        proc.environment = procEnv

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()

        // Drain stderr continuously to prevent XNU pipe buffer exhaustion (64KB deadlock)
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw MCPClientError.processStartFailed("Could not start \(command): \(error.localizedDescription)")
        }

        self.process = proc
        self.stdinPipe = inPipe
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe
    }

    /// Stops the subprocess and closes pipes.
    func stop() {
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        if let proc = process, proc.isRunning {
            proc.terminate()
            proc.waitUntilExit()
        }
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        isInitialized = false
    }

    // MARK: - Handshake & Tool Discovery

    /// Performs the initialize handshake and returns all available tools.
    func initializeAndListTools(timeout: TimeInterval = 15) async throws -> [MCPTool] {
        try start()

        if !isInitialized {
            let reqID = getNextID()
            let initReq = MCPJSONRPC.initializeRequest(id: reqID)
            let initResp = try await sendRequest(initReq, expectedID: reqID, timeout: timeout)
            guard let (_, result, error) = MCPJSONRPC.parseResponse(line: initResp) else {
                throw MCPClientError.invalidResponse("Invalid response during initialize.")
            }
            if let error {
                let msg = (error["message"] as? String) ?? "Initialize error"
                throw MCPClientError.serverError(msg)
            }
            guard result != nil else {
                throw MCPClientError.invalidResponse("Missing result in initialize.")
            }

            // Send notification
            let initNotif = MCPJSONRPC.initializedNotification()
            try sendData(initNotif)
            isInitialized = true
        }

        // Fetch tools
        let reqID = getNextID()
        let listReq = MCPJSONRPC.toolsListRequest(id: reqID)
        let listResp = try await sendRequest(listReq, expectedID: reqID, timeout: timeout)
        guard let (_, result, error) = MCPJSONRPC.parseResponse(line: listResp) else {
            throw MCPClientError.invalidResponse("Invalid response for tools/list.")
        }
        if let error {
            let msg = (error["message"] as? String) ?? "tools/list error"
            throw MCPClientError.serverError(msg)
        }
        guard let result else {
            return []
        }

        return MCPJSONRPC.parseToolsList(result: result, serverID: config.id, serverName: config.name)
    }

    /// Calls an MCP tool with arguments.
    func callTool(name: String, arguments: [String: AnyCodable], timeout: TimeInterval = 60) async throws -> MCPToolResult {
        try start()
        if !isInitialized {
            _ = try await initializeAndListTools()
        }

        let reqID = getNextID()
        let req = MCPJSONRPC.toolCallRequest(id: reqID, name: name, arguments: arguments)
        let resp = try await sendRequest(req, expectedID: reqID, timeout: timeout)
        guard let (_, result, error) = MCPJSONRPC.parseResponse(line: resp) else {
            throw MCPClientError.invalidResponse("Invalid response for tools/call.")
        }
        return MCPJSONRPC.parseToolCallResult(result: result, error: error)
    }

    // MARK: - Pipe Transport

    private func getNextID() -> Int {
        let id = nextRequestID
        nextRequestID += 1
        return id
    }

    private func sendData(_ text: String) throws {
        guard let handle = stdinPipe?.fileHandleForWriting,
              let data = text.data(using: .utf8) else {
            throw MCPClientError.processStartFailed("Process stdin is closed.")
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw MCPClientError.processStartFailed("Failed writing to stdin: \(error.localizedDescription)")
        }
    }

    private func sendRequest(_ requestText: String, expectedID: Int, timeout: TimeInterval) async throws -> String {
        try sendData(requestText)

        guard let stdoutHandle = stdoutPipe?.fileHandleForReading else {
            throw MCPClientError.processStartFailed("Process stdout is closed.")
        }

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                for try await line in stdoutHandle.bytes.lines {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty && trimmed.hasPrefix("{") else { continue }
                    // Filter by expected JSON-RPC id to prevent desync on asynchronous events/notifications
                    if let parsed = MCPJSONRPC.parseResponse(line: trimmed), let respID = parsed.id {
                        if respID == expectedID {
                            return trimmed
                        }
                    }
                }
                throw MCPClientError.terminated
            }

            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw MCPClientError.timeout("Request timed out after \(timeout)s.")
            }

            guard let firstResult = try await group.next() else {
                throw MCPClientError.invalidResponse("No response received.")
            }
            group.cancelAll()
            return firstResult
        }
    }

    // MARK: - Binary Resolution

    private func resolveExecutable(_ command: String) -> String {
        if command.hasPrefix("/") { return command }
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/\(command)",
            "/usr/local/bin/\(command)",
            "/usr/bin/\(command)",
            "\(home)/.local/bin/\(command)",
            "\(home)/.nvm/versions/node/current/bin/\(command)"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/\(command)"
    }
}
#else
/// Sandboxed fallback for the Mac App Store and iOS builds: subprocesses are disabled.
actor MCPStdioClient: MCPClientProtocol {
    let config: MCPServerConfig
    init(config: MCPServerConfig) {
        self.config = config
    }
    func initializeAndListTools(timeout: TimeInterval = 15) async throws -> [MCPTool] {
        return []
    }
    func callTool(name: String, arguments: [String: AnyCodable], timeout: TimeInterval = 60) async throws -> MCPToolResult {
        return MCPToolResult(content: "Command-line MCP tools are disabled in this build. Use remote HTTP MCP servers instead.", isError: true)
    }
}
#endif
