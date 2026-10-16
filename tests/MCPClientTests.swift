import Foundation

@main
enum MCPClientTests {
    static func main() throws {
        var cases = 0
        func check(_ ok: Bool, _ what: String, line: UInt = #line) {
            precondition(ok, "\(what) (line \(line))")
            cases += 1
        }

        // MARK: - JSON-RPC Request Building
        let initReq = MCPJSONRPC.initializeRequest(id: 1, clientName: "Coucou", version: "0.3.0")
        check(initReq.hasSuffix("\n"), "requests are newline terminated")
        check(initReq.contains(#""jsonrpc":"2.0""#), "contains jsonrpc version")
        check(initReq.contains(#""method":"initialize""#), "method is initialize")
        check(initReq.contains(#""protocolVersion":"2024-11-05""#), "mcp protocol version declared")

        let toolsReq = MCPJSONRPC.toolsListRequest(id: 2)
        check(toolsReq.contains(#""method":"tools/list""#), "tools/list method")

        let args: [String: AnyCodable] = [
            "path": .string("/tmp/test.txt"),
            "limit": .int(10)
        ]
        let callReq = MCPJSONRPC.toolCallRequest(id: 3, name: "read_file", arguments: args)
        check(callReq.contains(#""method":"tools/call""#), "tools/call method")
        check(callReq.contains(#""name":"read_file""#), "tool name in params")
        check(callReq.contains(#"/tmp/test.txt"#), "argument string serialized")

        // MARK: - JSON-RPC Response Parsing
        let validRespLine = #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{}}}"#
        let parsed = MCPJSONRPC.parseResponse(line: validRespLine)
        check(parsed != nil, "parses valid response")
        check(parsed?.id == 1, "id matches")
        check(parsed?.result != nil, "result is present")
        check(parsed?.error == nil, "error is nil")

        let errRespLine = #"{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"Method not found"}}"#
        let parsedErr = MCPJSONRPC.parseResponse(line: errRespLine)
        check(parsedErr?.error != nil, "parsed error block")
        check((parsedErr?.error?["code"] as? Int) == -32601, "error code matches")

        // MARK: - Tools List Parsing & Safety Classification
        let toolsResultObj: [String: Any] = [
            "tools": [
                [
                    "name": "get_weather",
                    "description": "Fetch current weather",
                    "inputSchema": [
                        "type": "object",
                        "properties": ["city": ["type": "string"]]
                    ]
                ],
                [
                    "name": "delete_database",
                    "description": "Drop tables",
                    "readOnlyHint": false,
                    "inputSchema": ["type": "object"]
                ],
                [
                    "name": "custom_reader",
                    "description": "Reads something",
                    "readOnlyHint": true,
                    "inputSchema": ["type": "object"]
                ],
                [
                    "name": "execute_shell",
                    "description": "Runs a command",
                    "inputSchema": ["type": "object"]
                ]
            ]
        ]

        let tools = MCPJSONRPC.parseToolsList(result: toolsResultObj, serverID: "demo", serverName: "Demo Server")
        check(tools.count == 4, "parsed 4 tools")

        let weather = tools.first { $0.name == "get_weather" }
        check(weather?.isReadOnly == true, "get_ prefix inferred as read-only")
        check(weather?.id == "mcp__demo__get_weather", "qualified id generated")

        let dropDb = tools.first { $0.name == "delete_database" }
        check(dropDb?.isReadOnly == false, "mutating tool classified as NOT read-only")

        let customReader = tools.first { $0.name == "custom_reader" }
        check(customReader?.isReadOnly == true, "honors readOnlyHint: true")

        let shell = tools.first { $0.name == "execute_shell" }
        check(shell?.isReadOnly == false, "execute_ keyword fails closed to not read-only")

        // MARK: - Tool Call Result Parsing
        let toolSuccessObj: [String: Any] = [
            "content": [
                ["type": "text", "text": "22°C and sunny in Buenos Aires"]
            ],
            "isError": false
        ]
        let toolSuccess = MCPJSONRPC.parseToolCallResult(result: toolSuccessObj, error: nil)
        check(!toolSuccess.isError, "tool call succeeded")
        check(toolSuccess.content == "22°C and sunny in Buenos Aires", "content extracted")

        let toolFailure = MCPJSONRPC.parseToolCallResult(result: nil, error: ["message": "File not found"])
        check(toolFailure.isError, "tool failure detected")
        check(toolFailure.content == "File not found", "error message extracted")

        // MARK: - OpenAI Bridge
        let openAIFunc = MCPJSONRPC.openAIToolDefinition(for: weather!)
        check(openAIFunc["type"] as? String == "function", "openai type is function")
        if let fn = openAIFunc["function"] as? [String: Any] {
            check(fn["name"] as? String == "mcp__demo__get_weather", "function name matches qualified id")
            check(fn["parameters"] != nil, "parameters schema present")
        } else {
            check(false, "function object missing")
        }

        let decodedName = MCPJSONRPC.decodeFunctionName("mcp__demo__get_weather")
        check(decodedName?.serverID == "demo" && decodedName?.toolName == "get_weather", "decoded function name")
        let decodedComplex = MCPJSONRPC.decodeFunctionName("mcp__github_mcp__create_issue")
        check(decodedComplex?.serverID == "github_mcp" && decodedComplex?.toolName == "create_issue", "decoded name with underscores in serverID and toolName")
        check(MCPJSONRPC.decodeFunctionName("unrelated_func") == nil, "rejects non-mcp function name")

        // MARK: - AnyCodable SerDe
        let dict: [String: AnyCodable] = [
            "text": .string("hola"),
            "count": .int(42),
            "ratio": .double(3.14),
            "flag": .bool(true),
            "nested": .dictionary(["key": .string("val")]),
            "list": .array([.int(1), .int(2)])
        ]
        let encodedData = try JSONEncoder().encode(dict)
        let decodedDict = try JSONDecoder().decode([String: AnyCodable].self, from: encodedData)
        check(decodedDict == dict, "AnyCodable encodes and decodes losslessly")

        print("All \(cases) MCPClient tests passed.")
    }
}
