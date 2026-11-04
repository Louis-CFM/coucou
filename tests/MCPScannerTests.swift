import Foundation

@main
enum MCPScannerTests {
    static func main() throws {
        var cases = 0
        func check(_ ok: Bool, _ what: String, line: UInt = #line) {
            precondition(ok, "\(what) (line \(line))")
            cases += 1
        }

        let testHome = "/Users/testuser"
        let testEnv = ["MY_TOKEN": "secret_abc_123", "PORT": "8080"]

        // MARK: - Normalisation Tests
        check(MCPScanner.normaliseValue("~/Documents/db.sqlite", home: testHome) == "/Users/testuser/Documents/db.sqlite", "expands tilde prefix")
        check(MCPScanner.normaliseValue("${userHome}/.local/bin", home: testHome) == "/Users/testuser/.local/bin", "expands userHome token")
        check(MCPScanner.normaliseValue("${env:MY_TOKEN}", home: testHome, env: testEnv) == "secret_abc_123", "expands ${env:VAR}")
        check(MCPScanner.normaliseValue("{env:MY_TOKEN}", home: testHome, env: testEnv) == "secret_abc_123", "expands {env:VAR}")
        check(MCPScanner.normaliseValue("${PORT}", home: testHome, env: testEnv) == "8080", "expands standard ${VAR}")
        check(MCPScanner.normaliseValue("${HOST:-localhost}", home: testHome, env: testEnv) == "localhost", "resolves fallback default when unset")
        check(MCPScanner.normaliseValue("${PORT:-3000}", home: testHome, env: testEnv) == "8080", "prefers env value over fallback default")
        check(MCPScanner.normaliseValue("plain-value", home: testHome, env: testEnv) == "plain-value", "leaves plain value unchanged")

        // MARK: - Masking Tests
        check(MCPScanner.isSecretKey("GITHUB_TOKEN"), "detects token keyword")
        check(MCPScanner.isSecretKey("api_secret_key"), "detects secret and key keywords")
        check(!MCPScanner.isSecretKey("PORT"), "does not falsely flag PORT as secret")
        check(MCPScanner.maskPotentialSecret("ghp_1234567890abcdef") == "ghp_••••", "masks github token")
        check(MCPScanner.maskPotentialSecret("sk-1234567890abcdef") == "sk-1••••", "masks openai token")
        check(MCPScanner.maskPotentialSecret("normal_value") == "normal_value", "keeps non-token value")
        check(MCPScanner.maskURL("https://api.example.com/mcp?token=xyz123") == "https://api.example.com/mcp?••••", "masks url query params")

        // MARK: - Claude Desktop Format Parsing
        let claudeDesktopJSON = Data("""
        {
          "mcpServers": {
            "github": {
              "command": "npx",
              "args": ["-y", "@modelcontextprotocol/server-github"],
              "env": {
                "GITHUB_PERSONAL_ACCESS_TOKEN": "ghp_mocktoken123"
              }
            },
            "linear-remote": {
              "url": "https://mcp.linear.app/mcp",
              "headers": {
                "Authorization": "Bearer mock-token"
              }
            }
          }
        }
        """.utf8)

        let claudeParsed = MCPScanner.parseStandardMCPServers(data: claudeDesktopJSON, source: .claudeDesktop, home: testHome)
        check(claudeParsed.count == 2, "parsed two claude desktop servers")
        check(claudeParsed[0].name == "github", "first server is github")
        check(claudeParsed[0].sources == [.claudeDesktop], "source is claudeDesktop")
        if case .stdio(let cmd, let args, let env) = claudeParsed[0].transport {
            check(cmd == "npx", "stdio command is npx")
            check(args == ["-y", "@modelcontextprotocol/server-github"], "args match")
            check(env["GITHUB_PERSONAL_ACCESS_TOKEN"] == "ghp_mocktoken123", "env matches")
        } else {
            check(false, "expected stdio transport for github")
        }

        if case .http(let url, let headers) = claudeParsed[1].transport {
            check(url == "https://mcp.linear.app/mcp", "http url matches")
            check(headers["Authorization"] == "Bearer mock-token", "headers match")
        } else {
            check(false, "expected http transport for linear-remote")
        }

        // MARK: - VS Code Format Parsing
        let vscodeJSON = Data("""
        {
          "servers": {
            "postgres-db": {
              "command": "npx",
              "args": ["-y", "@modelcontextprotocol/server-postgres@0.1.2", "postgresql://localhost/mydb"],
              "env": {
                "PGPASSWORD": "pass"
              }
            }
          }
        }
        """.utf8)

        let vscodeParsed = MCPScanner.parseVSCodeConfig(data: vscodeJSON, home: testHome)
        check(vscodeParsed.count == 1, "parsed one vscode server")
        check(vscodeParsed[0].name == "postgres-db", "server name is postgres-db")
        check(vscodeParsed[0].sources == [.vscode], "source is vscode")

        // MARK: - OpenCode Format Parsing
        let opencodeJSON = Data("""
        {
          "mcp": {
            "filesystem": {
              "type": "local",
              "command": ["npx", "-y", "@modelcontextprotocol/server-filesystem", "~/Projects"],
              "environment": {
                "READONLY": "true"
              }
            }
          }
        }
        """.utf8)

        let opencodeParsed = MCPScanner.parseOpenCodeConfig(data: opencodeJSON, home: testHome)
        check(opencodeParsed.count == 1, "parsed one opencode server")
        check(opencodeParsed[0].name == "filesystem", "name is filesystem")
        check(opencodeParsed[0].sources == [.opencode], "source is opencode")
        if case .stdio(let cmd, let args, let env) = opencodeParsed[0].transport {
            check(cmd == "npx", "command is npx")
            check(args == ["-y", "@modelcontextprotocol/server-filesystem", "/Users/testuser/Projects"], "arg tilde expanded")
            check(env["READONLY"] == "true", "environment mapped")
        } else {
            check(false, "expected stdio transport for opencode server")
        }

        // MARK: - Deduplication Tests
        let server1 = MCPServerConfig(id: "pg", name: "PostgreSQL", sources: [.claudeDesktop],
                                     transport: .stdio(command: "npx", args: ["-y", "@modelcontextprotocol/server-postgres@1.0.0", "db1"], env: [:]))
        let server2 = MCPServerConfig(id: "pg-cursor", name: "PostgreSQL", sources: [.cursor],
                                     transport: .stdio(command: "npx", args: ["-y", "@modelcontextprotocol/server-postgres@1.0.5", "db1"], env: [:]))

        let deduped = MCPScanner.deduplicate(servers: [server1, server2])
        check(deduped.count == 1, "deduplicated identical postgres servers despite package version differences")
        check(deduped[0].sources.contains(.claudeDesktop) && deduped[0].sources.contains(.cursor), "merged sources contains both claudeDesktop and cursor")

        // MARK: - Resilient Error Handling
        check(MCPScanner.parseStandardMCPServers(data: Data("<html></html>".utf8), source: .claudeDesktop, home: testHome).isEmpty, "survives html junk")
        check(MCPScanner.parseStandardMCPServers(data: Data("{}".utf8), source: .claudeDesktop, home: testHome).isEmpty, "survives empty json")
        check(MCPScanner.parseOpenCodeConfig(data: Data("{ \"invalid\": true }".utf8), home: testHome).isEmpty, "survives unexpected keys")

        // MARK: - ScanAll with Injected File Reader
        let mockFiles: [String: Data] = [
            "/Users/testuser/Library/Application Support/Claude/claude_desktop_config.json": claudeDesktopJSON,
            "/Users/testuser/.cursor/mcp.json": Data("""
            {
              "mcpServers": {
                "github": {
                  "command": "npx",
                  "args": ["-y", "@modelcontextprotocol/server-github"],
                  "env": {}
                }
              }
            }
            """.utf8)
        ]

        let scanned = MCPScanner.scanAll(home: testHome) { path in
            mockFiles[path]
        }

        check(scanned.count == 2, "scanAll returned github and linear-remote")
        let githubConfig = scanned.first { $0.name == "github" }
        check(githubConfig != nil, "found github config")
        check(githubConfig?.sources.contains(.claudeDesktop) == true, "github includes claudeDesktop")
        check(githubConfig?.sources.contains(.cursor) == true, "github includes cursor")

        // MARK: - Legacy SSE Transport Check
        let sseJSON = Data("""
        {
          "mcpServers": {
            "old-server": {
              "url": "https://example.com/sse",
              "type": "sse"
            }
          }
        }
        """.utf8)
        let sseParsed = MCPScanner.parseStandardMCPServers(data: sseJSON, source: .claudeDesktop, home: testHome)
        check(sseParsed.count == 1, "parsed sse server")
        check(!sseParsed[0].isEnabled, "legacy sse server disabled by default")
        check(sseParsed[0].notes.contains { $0.contains("Legacy SSE transport is deprecated") }, "legacy sse noted")

        // MARK: - Windows Candidates Check
        let winCandidates = MCPScanner.candidatePaths(home: "C:/Users/testuser", appData: "C:/Users/testuser/AppData/Roaming")
        check(winCandidates.contains { $0.path.contains("AppData/Roaming/Claude/claude_desktop_config.json") }, "found windows claude path")
        check(winCandidates.contains { $0.path.contains("AppData/Roaming/Code/User/mcp.json") }, "found windows vscode path")

        print("All \(cases) MCPScanner tests passed.")
    }
}
