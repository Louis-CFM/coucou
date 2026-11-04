import Foundation

/// Actor managing communication with a remote streamable HTTP MCP server.
actor MCPHTTPClient: MCPClientProtocol {

    let config: MCPServerConfig
    private var nextRequestID = 1
    private var isInitialized = false
    private let session: URLSession

    init(config: MCPServerConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    // MARK: - MCPClientProtocol

    func initializeAndListTools(timeout: TimeInterval = 10) async throws -> [MCPTool] {
        guard case .http(let endpointURL, _) = config.transport else {
            throw MCPClientError.invalidResponse("Server config is not an HTTP transport.")
        }

        if !isInitialized {
            let initReqText = MCPJSONRPC.initializeRequest(id: getNextID())
            let initResp = try await sendPost(requestBody: initReqText, url: endpointURL, timeout: timeout)
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
            _ = try? await sendPost(requestBody: initNotif, url: endpointURL, timeout: timeout)
            isInitialized = true
        }

        let listReqText = MCPJSONRPC.toolsListRequest(id: getNextID())
        let listResp = try await sendPost(requestBody: listReqText, url: endpointURL, timeout: timeout)
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

    func callTool(name: String, arguments: [String: AnyCodable], timeout: TimeInterval = 60) async throws -> MCPToolResult {
        guard case .http(let endpointURL, _) = config.transport else {
            throw MCPClientError.invalidResponse("Server config is not an HTTP transport.")
        }

        if !isInitialized {
            _ = try await initializeAndListTools()
        }

        let callReqText = MCPJSONRPC.toolCallRequest(id: getNextID(), name: name, arguments: arguments)
        let resp = try await sendPost(requestBody: callReqText, url: endpointURL, timeout: timeout)
        guard let (_, result, error) = MCPJSONRPC.parseResponse(line: resp) else {
            throw MCPClientError.invalidResponse("Invalid response for tools/call.")
        }
        return MCPJSONRPC.parseToolCallResult(result: result, error: error)
    }

    // MARK: - HTTP Transport

    private func getNextID() -> Int {
        let id = nextRequestID
        nextRequestID += 1
        return id
    }

    private func sendPost(requestBody: String, url: String, timeout: TimeInterval) async throws -> String {
        guard let endpoint = URL(string: url) else {
            throw MCPClientError.invalidResponse("Invalid endpoint URL: \(url)")
        }

        var req = URLRequest(url: endpoint, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if case .http(_, let headers) = config.transport {
            for (key, val) in headers {
                req.setValue(val, forHTTPHeaderField: key)
            }
        }

        req.httpBody = Data(requestBody.utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let err as URLError {
            if err.code == .timedOut {
                throw MCPClientError.timeout("HTTP request timed out after \(timeout)s.")
            } else {
                throw MCPClientError.serverError("Network error: \(err.localizedDescription)")
            }
        } catch {
            throw MCPClientError.serverError("HTTP request failed: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw MCPClientError.invalidResponse("No HTTP response received.")
        }

        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw MCPClientError.serverError("Authentication failed for \(url). Check your credentials.")
            }
            throw MCPClientError.serverError("HTTP \(http.statusCode) returned by \(url)")
        }

        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw MCPClientError.invalidResponse("Malformed response text.")
        }

        return text
    }
}
