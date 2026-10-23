import Foundation

/// Discovers existing MCP server configurations from developer tools on this machine.
/// All scans are read-only and never write or modify any files on disk.
enum MCPScanner {

    // MARK: - Variable Normalisation

    /// Normalises environment variable tokens from different tool formats:
    /// - `${VAR}` (Claude Code, shell)
    /// - `${env:VAR}` (VS Code, Cursor, Windsurf)
    /// - `{env:VAR}` (OpenCode)
    /// - `${userHome}` -> user's home directory
    /// - `~/` -> user's home directory
    static func normaliseValue(_ raw: String, home: String, env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        var s = raw
        if s.hasPrefix("~/") {
            s = "\(home)/" + s.dropFirst(2)
        }
        s = s.replacingOccurrences(of: "${userHome}", with: home)

        // Regex: \$\{env:([A-Za-z0-9_]+)\} or \{env:([A-Za-z0-9_]+)\} -> ${$1}
        let envPrefixPattern = #"(?:\$\{env:|\{env:)([A-Za-z0-9_]+)\}"#
        if let regex = try? NSRegularExpression(pattern: envPrefixPattern) {
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            s = regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: #"\${$1}"#)
        }

        // Support ${NAME:-default}
        let fallbackPattern = #"\$\{([A-Za-z0-9_]+):-([^}]*)\}"#
        if let regex = try? NSRegularExpression(pattern: fallbackPattern) {
            let matches = regex.matches(in: s, range: NSRange(s.startIndex..<s.endIndex, in: s))
            for match in matches.reversed() {
                guard let fullRange = Range(match.range, in: s),
                      let keyRange = Range(match.range(at: 1), in: s),
                      let defaultRange = Range(match.range(at: 2), in: s) else { continue }
                let key = String(s[keyRange])
                let def = String(s[defaultRange])
                let val = env[key] ?? def
                s.replaceSubrange(fullRange, with: val)
            }
        }

        // Expand known environment variables if available
        let varPattern = #"\$\{([A-Za-z0-9_]+)\}"#
        if let regex = try? NSRegularExpression(pattern: varPattern) {
            let matches = regex.matches(in: s, range: NSRange(s.startIndex..<s.endIndex, in: s))
            for match in matches.reversed() {
                guard let fullRange = Range(match.range, in: s),
                      let keyRange = Range(match.range(at: 1), in: s) else { continue }
                let key = String(s[keyRange])
                if let val = env[key] {
                    s.replaceSubrange(fullRange, with: val)
                }
            }
        }
        return s
    }

    // MARK: - Secret Masking for UI Display

    private static let credentialKeywords = ["token", "secret", "key", "pass", "auth", "cred", "bearer"]

    /// Checks if a key name suggests a secret (API key, auth token, etc.)
    static func isSecretKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        return credentialKeywords.contains { lower.contains($0) }
    }

    /// Masks sensitive values or arguments for safe display in settings.
    static func maskPotentialSecret(_ val: String) -> String {
        if val.count > 12 && (val.hasPrefix("sk-") || val.hasPrefix("ghp_") || val.hasPrefix("glpat-") || val.hasPrefix("xoxb-")) {
            return String(val.prefix(4)) + "••••"
        }
        return val
    }

    /// Masks sensitive components of URLs (removes query strings or user/passwords).
    static func maskURL(_ rawURL: String) -> String {
        guard let url = URL(string: rawURL), var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return rawURL }
        comps.user = nil
        comps.password = nil
        if comps.query != nil {
            comps.percentEncodedQuery = "%E2%80%A2%E2%80%A2%E2%80%A2%E2%80%A2"
        }
        // Decode percent-encoded bullet points if returned as %E2%80%A2
        if let s = comps.string {
            return s.replacingOccurrences(of: "%E2%80%A2%E2%80%A2%E2%80%A2%E2%80%A2", with: "••••")
        }
        return rawURL
    }

    // MARK: - Parsing Tools

    /// Parses standard `mcpServers` JSON structure used by Claude Desktop, Cursor, Claude Code, and Windsurf.
    static func parseStandardMCPServers(data: Data, source: MCPServerSource, home: String) -> [MCPServerConfig] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var result: [MCPServerConfig] = []

        // Top-level "mcpServers" dict
        if let serversDict = json["mcpServers"] as? [String: Any] {
            result += parseServerDictionary(serversDict, source: source, home: home)
        }

        // Claude Code can also store servers inside projects: "projects": { "<path>": { "mcpServers": { ... } } }
        if let projectsDict = json["projects"] as? [String: Any] {
            for (_, projVal) in projectsDict {
                if let projObj = projVal as? [String: Any],
                   let serversDict = projObj["mcpServers"] as? [String: Any] {
                    result += parseServerDictionary(serversDict, source: source, home: home)
                }
            }
        }
        return result
    }

    /// Parses VS Code `mcp.json` which can use either "servers" or "mcpServers".
    static func parseVSCodeConfig(data: Data, home: String) -> [MCPServerConfig] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var result: [MCPServerConfig] = []

        if let servers = json["servers"] as? [String: Any] {
            result += parseServerDictionary(servers, source: .vscode, home: home)
        }
        if let mcpServers = json["mcpServers"] as? [String: Any] {
            result += parseServerDictionary(mcpServers, source: .vscode, home: home)
        }
        return result
    }

    /// Parses OpenCode `opencode.json` which uses "mcp": { "<name>": { ... } }.
    static func parseOpenCodeConfig(data: Data, home: String) -> [MCPServerConfig] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        guard let mcpDict = (json["mcp"] as? [String: Any]) ?? (json["mcpServers"] as? [String: Any]) else { return [] }

        var result: [MCPServerConfig] = []
        for (name, rawVal) in mcpDict {
            guard let serverObj = rawVal as? [String: Any] else { continue }

            // OpenCode can provide command as an array or as command + args
            var command = ""
            var args: [String] = []

            if let cmdArray = serverObj["command"] as? [String], !cmdArray.isEmpty {
                command = normaliseValue(cmdArray[0], home: home)
                args = cmdArray.dropFirst().map { normaliseValue($0, home: home) }
            } else if let cmdString = serverObj["command"] as? String {
                command = normaliseValue(cmdString, home: home)
                if let argsArray = serverObj["args"] as? [String] {
                    args = argsArray.map { normaliseValue($0, home: home) }
                }
            } else if let urlString = serverObj["url"] as? String {
                let normURL = normaliseValue(urlString, home: home)
                let headers = (serverObj["headers"] as? [String: String]) ?? [:]
                let id = slug(from: name, existing: result.map(\.id))
                result.append(MCPServerConfig(id: id, name: name, sources: [.opencode],
                                              transport: .http(url: normURL, headers: headers)))
                continue
            }

            guard !command.isEmpty else { continue }

            var envMap: [String: String] = [:]
            let rawEnv = (serverObj["environment"] as? [String: String]) ?? (serverObj["env"] as? [String: String]) ?? [:]
            for (k, v) in rawEnv {
                envMap[k] = normaliseValue(v, home: home)
            }

            let id = slug(from: name, existing: result.map(\.id))
            result.append(MCPServerConfig(id: id, name: name, sources: [.opencode],
                                          transport: .stdio(command: command, args: args, env: envMap)))
        }
        return result
    }

    private static func parseServerDictionary(_ dict: [String: Any], source: MCPServerSource, home: String) -> [MCPServerConfig] {
        var result: [MCPServerConfig] = []
        for name in dict.keys.sorted() {
            guard let val = dict[name], let serverObj = val as? [String: Any] else { continue }

            if let urlString = serverObj["url"] as? String {
                let normURL = normaliseValue(urlString, home: home)
                let headers = (serverObj["headers"] as? [String: String]) ?? [:]
                let id = slug(from: name, existing: result.map(\.id))
                let isLegacySSE = (serverObj["type"] as? String)?.lowercased() == "sse" || normURL.lowercased().hasSuffix("/sse")
                var notes: [String] = []
                if isLegacySSE {
                    notes.append("Legacy SSE transport is deprecated; streamable HTTP POST is recommended.")
                }
                result.append(MCPServerConfig(id: id, name: name, sources: [source],
                                              transport: .http(url: normURL, headers: headers),
                                              isEnabled: !isLegacySSE,
                                              notes: notes))
                continue
            }

            guard let rawCommand = serverObj["command"] as? String else { continue }
            let command = normaliseValue(rawCommand, home: home)
            let rawArgs = (serverObj["args"] as? [String]) ?? []
            let args = rawArgs.map { normaliseValue($0, home: home) }

            var envMap: [String: String] = [:]
            var notes: [String] = []
            if let rawEnv = serverObj["env"] as? [String: String] {
                for (k, v) in rawEnv {
                    let normV = normaliseValue(v, home: home)
                    envMap[k] = normV
                    if normV.contains("${input:") {
                        notes.append("Requires setup: input value for '\(k)' needs to be provided.")
                    }
                }
            }

            let id = slug(from: name, existing: result.map(\.id))
            result.append(MCPServerConfig(id: id, name: name, sources: [source],
                                          transport: .stdio(command: command, args: args, env: envMap),
                                          notes: notes))
        }
        return result
    }

    // MARK: - Identity & Deduplication

    /// Fingerprint used to detect identical servers across different tool configs.
    private static func fingerprint(for transport: MCPTransport) -> String {
        switch transport {
        case .stdio(let command, let args, _):
            // Strip npm version specifiers (e.g. @modelcontextprotocol/server-postgres@0.1.2 -> @modelcontextprotocol/server-postgres)
            let cleanArgs = args.map { arg in
                arg.replacingOccurrences(of: #"@[0-9]+\.[0-9]+(\.[0-9]+)?"#, with: "", options: .regularExpression)
            }
            return "stdio:\((command as NSString).lastPathComponent):" + cleanArgs.joined(separator: " ")
        case .http(let url, _):
            return "http:" + url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
    }

    /// Merges multiple configs pointing to the same underlying server into a unified entry.
    static func deduplicate(servers: [MCPServerConfig]) -> [MCPServerConfig] {
        var merged: [String: MCPServerConfig] = [:]
        var order: [String] = []

        for server in servers {
            let fp = fingerprint(for: server.transport)
            if var existing = merged[fp] {
                for src in server.sources where !existing.sources.contains(src) {
                    existing.sources.append(src)
                }
                merged[fp] = existing
            } else {
                merged[fp] = server
                order.append(fp)
            }
        }
        return order.compactMap { merged[$0] }
    }

    /// Creates a clean, safe ASCII slug from a display name.
    static func slug(from name: String, existing: [String]) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let dashed = folded.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? String($0) : "-" }.joined()
        let words = dashed.split(separator: "-").map(String.init)
        let base = words.isEmpty ? "mcp-server" : words.joined(separator: "-")
        var candidate = base
        var counter = 2
        while existing.contains(candidate) {
            candidate = "\(base)-\(counter)"
            counter += 1
        }
        return candidate
    }

    // MARK: - Scanning Candidate Locations

    struct CandidatePath: Sendable {
        let path: String
        let source: MCPServerSource
    }

    /// Standard configuration file locations per developer tool across macOS, Linux, and Windows.
    static func candidatePaths(home: String,
                                appData: String? = ProcessInfo.processInfo.environment["APPDATA"],
                                xdgConfig: String? = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]) -> [CandidatePath] {
        let linuxConfig = (xdgConfig != nil && !xdgConfig!.isEmpty) ? xdgConfig! : "\(home)/.config"
        var paths = [
            // Claude Desktop
            CandidatePath(path: "\(home)/Library/Application Support/Claude/claude_desktop_config.json", source: .claudeDesktop),
            CandidatePath(path: "\(linuxConfig)/Claude/claude_desktop_config.json", source: .claudeDesktop),

            // Claude Code
            CandidatePath(path: "\(home)/.claude.json", source: .claudeCode),

            // Cursor
            CandidatePath(path: "\(home)/.cursor/mcp.json", source: .cursor),

            // VS Code
            CandidatePath(path: "\(home)/Library/Application Support/Code/User/mcp.json", source: .vscode),
            CandidatePath(path: "\(linuxConfig)/Code/User/mcp.json", source: .vscode),

            // Windsurf
            CandidatePath(path: "\(home)/.codeium/windsurf/mcp_config.json", source: .windsurf),

            // OpenCode
            CandidatePath(path: "\(linuxConfig)/opencode/opencode.json", source: .opencode),
            CandidatePath(path: "\(linuxConfig)/opencode/mcp.json", source: .opencode),
        ]

        // Windows candidates (when %APPDATA% is defined or in home folder)
        if let appData = appData, !appData.isEmpty {
            let cleanAppData = appData.replacingOccurrences(of: "\\", with: "/")
            paths.append(CandidatePath(path: "\(cleanAppData)/Claude/claude_desktop_config.json", source: .claudeDesktop))
            paths.append(CandidatePath(path: "\(cleanAppData)/Code/User/mcp.json", source: .vscode))
            paths.append(CandidatePath(path: "\(cleanAppData)/opencode/opencode.json", source: .opencode))
        } else {
            paths.append(CandidatePath(path: "\(home)/AppData/Roaming/Claude/claude_desktop_config.json", source: .claudeDesktop))
            paths.append(CandidatePath(path: "\(home)/AppData/Roaming/Code/User/mcp.json", source: .vscode))
        }

        return paths
    }

    /// Reads all detected configuration files and returns the deduplicated list of MCP servers.
    #if os(macOS)
    static func scanAll(home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                        fileReader: (String) -> Data? = { path in try? Data(contentsOf: URL(fileURLWithPath: path)) }) -> [MCPServerConfig] {
        var found: [MCPServerConfig] = []
        for candidate in candidatePaths(home: home) {
            guard let data = fileReader(candidate.path) else { continue }
            switch candidate.source {
            case .claudeDesktop, .claudeCode, .cursor, .windsurf:
                found += parseStandardMCPServers(data: data, source: candidate.source, home: home)
            case .vscode:
                found += parseVSCodeConfig(data: data, home: home)
            case .opencode:
                found += parseOpenCodeConfig(data: data, home: home)
            case .manual:
                break
            }
        }
        return deduplicate(servers: found)
    }
    #else
    static func scanAll(home: String = NSHomeDirectory(),
                        fileReader: (String) -> Data? = { path in try? Data(contentsOf: URL(fileURLWithPath: path)) }) -> [MCPServerConfig] {
        return []
    }
    #endif
}
