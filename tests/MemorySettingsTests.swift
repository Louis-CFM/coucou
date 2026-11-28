import Foundation

@main
enum MemorySettingsTests {
    static var fm: FileManager { .default }

    static func main() throws {
        let dir = fm.temporaryDirectory
            .appendingPathComponent("coucou-memory-settings-\(ProcessInfo.processInfo.processIdentifier)")
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let path = dir.appendingPathComponent("settings.json").path

        // 1. File absent — must throw fileNotFound, write nothing.
        do {
            try brainSettingsApply(path: path, backupPath: path + ".bak") { _ in }
            preconditionFailure("absent file must throw")
        } catch MemorySettingsError.fileNotFound { /* expected */ }
        precondition(!fm.fileExists(atPath: path), "absent file must not be created")

        // 2. Invalid JSON — must throw invalidJSON, file must stay as it was.
        let badJson = Data("{not json".utf8)
        fm.createFile(atPath: path, contents: badJson)
        do {
            try brainSettingsApply(path: path, backupPath: path + ".bak") { _ in }
            preconditionFailure("invalid JSON must throw")
        } catch MemorySettingsError.invalidJSON { /* expected */ }
        precondition(fm.contents(atPath: path) == badJson, "invalid JSON: file must be unchanged")

        // 3. Backup impossible — read-only dir for backup target — must throw backupFailed.
        let baseJson = Data(#"{"model":"claude-opus","other":"kept"}"#.utf8)
        fm.createFile(atPath: path, contents: baseJson)
        let roDir = dir.appendingPathComponent("readonly").path
        try fm.createDirectory(atPath: roDir, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o444)], ofItemAtPath: roDir)
        let roBackup = roDir + "/settings.json.bak"
        do {
            try brainSettingsApply(path: path, backupPath: roBackup) { _ in }
            preconditionFailure("backup in read-only dir must throw")
        } catch MemorySettingsError.backupFailed { /* expected */ }
        precondition(fm.contents(atPath: path) == baseJson, "backup failure: file must be unchanged")
        // Restore permissions for cleanup.
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: roDir)

        // 4. Add brain hooks — verify SessionStart + UserPromptSubmit entries present.
        let initial = Data(#"{"model":"claude-opus","other":"kept"}"#.utf8)
        fm.createFile(atPath: path, contents: initial)
        let backupPath = path + ".bak-add"
        try brainSettingsApply(path: path, backupPath: backupPath) { json in
            brainHooksAdd(to: &json, hooksDir: "/hooks", nodeCmd: "/usr/bin/node")
        }
        let afterAdd = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        let hooks = afterAdd["hooks"] as? [String: Any]
        precondition(hooks != nil, "hooks key must exist after add")
        let ss = hooks?["SessionStart"] as? [[String: Any]]
        precondition(ss?.isEmpty == false, "SessionStart must have entries after add")
        let ups = hooks?["UserPromptSubmit"] as? [[String: Any]]
        precondition(ups?.isEmpty == false, "UserPromptSubmit must have entries after add")
        // Check session-start command contains the hook path.
        let ssHook = (ss?.first?["hooks"] as? [[String: Any]])?.first
        precondition((ssHook?["command"] as? String)?.contains("brain-session-start.js") == true,
                     "SessionStart hook must reference brain-session-start.js")
        // Other settings preserved.
        precondition(afterAdd["model"] as? String == "claude-opus", "model key must be preserved")
        precondition(afterAdd["other"] as? String == "kept", "other key must be preserved")
        // Backup created.
        precondition(fm.fileExists(atPath: backupPath), "backup must be created on success")

        // 5. Remove brain hooks — verify gone, other settings + non-brain hooks preserved.
        // Start from a file that already has another hook alongside ours.
        let mixedHooks: [String: Any] = [
            "model": "claude-opus",
            "other": "kept",
            "hooks": [
                "SessionStart": [
                    ["hooks": [["type": "command", "command": "/usr/bin/node \"/hooks/brain-session-start.js\"", "timeout": 8]]],
                    ["hooks": [["type": "command", "command": "other-tool"]]],
                ],
                "UserPromptSubmit": [
                    ["hooks": [["type": "command", "command": "/usr/bin/node \"/hooks/brain-prompt.js\"", "timeout": 5]]],
                ],
            ] as [String: Any],
        ]
        let mixedData = try JSONSerialization.data(withJSONObject: mixedHooks, options: [.prettyPrinted, .sortedKeys])
        try mixedData.write(to: URL(fileURLWithPath: path))
        let removeBackup = path + ".bak-remove"
        try brainSettingsApply(path: path, backupPath: removeBackup) { json in
            brainHooksRemove(from: &json)
        }
        let afterRemove = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        let hooksAfter = afterRemove["hooks"] as? [String: Any]
        let ssAfter = hooksAfter?["SessionStart"] as? [[String: Any]]
        // Brain entry removed; non-brain entry stays.
        precondition(ssAfter?.count == 1, "only non-brain SessionStart hook must remain")
        let otherCmd = ((ssAfter?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String)
        precondition(otherCmd == "other-tool", "non-brain hook must be preserved")
        let upsAfter = hooksAfter?["UserPromptSubmit"] as? [[String: Any]]
        precondition(upsAfter?.isEmpty == true || upsAfter == nil,
                     "brain UserPromptSubmit entry must be removed")
        precondition(afterRemove["model"] as? String == "claude-opus", "model must be preserved after remove")
        precondition(afterRemove["other"] as? String == "kept", "other key must be preserved after remove")

        // 6. Add MCP — coucou-brain entry must appear.
        fm.createFile(atPath: path, contents: Data(#"{"model":"opus"}"#.utf8))
        try brainSettingsApply(path: path, backupPath: path + ".bak-mcp-add") { json in
            brainMcpAdd(to: &json)
        }
        let afterMcpAdd = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        let mcpServers = afterMcpAdd["mcpServers"] as? [String: Any]
        precondition(mcpServers?["coucou-brain"] != nil, "coucou-brain MCP entry must be added")

        // 7. Remove MCP — coucou-brain gone, model preserved.
        try brainSettingsApply(path: path, backupPath: path + ".bak-mcp-remove") { json in
            brainMcpRemove(from: &json)
        }
        let afterMcpRemove = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        let mcpAfter = afterMcpRemove["mcpServers"] as? [String: Any]
        precondition(mcpAfter?["coucou-brain"] == nil, "coucou-brain MCP entry must be removed")
        precondition(afterMcpRemove["model"] as? String == "opus", "model must be preserved after MCP remove")

        print("Memory settings: all checks passed")
    }
}
