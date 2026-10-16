import Foundation

@main
enum MCPHTTPClientTests {
    static func main() throws {
        var cases = 0
        func check(_ ok: Bool, _ what: String, line: UInt = #line) {
            precondition(ok, "\(what) (line \(line))")
            cases += 1
        }

        // MARK: - HTTP Server Config
        let httpConfig = MCPServerConfig(
            id: "linear-mcp",
            name: "Linear",
            sources: [.claudeDesktop],
            transport: .http(url: "https://mcp.linear.app/mcp", headers: ["Authorization": "Bearer test-key"])
        )

        check(httpConfig.id == "linear-mcp", "config id matches")
        check(httpConfig.name == "Linear", "config name matches")
        if case .http(let url, let headers) = httpConfig.transport {
            check(url == "https://mcp.linear.app/mcp", "url matches")
            check(headers["Authorization"] == "Bearer test-key", "header matches")
        } else {
            check(false, "expected http transport")
        }

        // MARK: - Payload Construction
        let initPayload = MCPJSONRPC.initializeRequest(id: 1)
        check(initPayload.contains("protocolVersion"), "payload has protocol version")

        let toolsPayload = MCPJSONRPC.toolsListRequest(id: 2)
        check(toolsPayload.contains("tools/list"), "payload has tools/list")

        // MARK: - Remote Result Parsing
        let mockResponseLine = """
        {
          "jsonrpc": "2.0",
          "id": 2,
          "result": {
            "tools": [
              {
                "name": "linear_search_issues",
                "description": "Search issues in Linear",
                "readOnlyHint": true,
                "inputSchema": {
                  "type": "object",
                  "properties": {
                    "query": { "type": "string" }
                  }
                }
              }
            ]
          }
        }
        """

        let parsed = MCPJSONRPC.parseResponse(line: mockResponseLine)
        check(parsed?.id == 2, "response id is 2")
        check(parsed?.result != nil, "result is present")

        let tools = MCPJSONRPC.parseToolsList(result: parsed!.result!, serverID: httpConfig.id, serverName: httpConfig.name)
        check(tools.count == 1, "parsed 1 remote tool")
        check(tools[0].name == "linear_search_issues", "tool name matches")
        check(tools[0].isReadOnly == true, "readOnlyHint respected on remote tool")
        check(tools[0].id == "mcp__linear-mcp__linear_search_issues", "id correctly formatted")

        print("All \(cases) MCPHTTPClient tests passed.")
    }
}
