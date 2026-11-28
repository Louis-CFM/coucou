import Foundation

// MARK: - Pure settings.json manipulation (extracted for testability)
// No SwiftUI / AppKit / APPSTORE guard — compiles standalone with swiftc for tests.

enum MemorySettingsError: Error {
    case fileNotFound
    case invalidJSON
    case backupFailed(Error)
    case serializationError
    case writeFailed(Error)
}

/// Read → guard JSON → backup → modify → serialize → write atomically.
/// Throws on any failure so the caller can surface a localised error.
func brainSettingsApply(
    path: String,
    backupPath: String,
    modify: (inout [String: Any]) -> Void
) throws {
    guard let data = FileManager.default.contents(atPath: path) else {
        throw MemorySettingsError.fileNotFound
    }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw MemorySettingsError.invalidJSON
    }
    do {
        try FileManager.default.copyItem(atPath: path, toPath: backupPath)
    } catch {
        throw MemorySettingsError.backupFailed(error)
    }
    var updated = json
    modify(&updated)
    guard let newData = try? JSONSerialization.data(withJSONObject: updated,
                                                    options: [.prettyPrinted, .sortedKeys]) else {
        throw MemorySettingsError.serializationError
    }
    do {
        try newData.write(to: URL(fileURLWithPath: path), options: .atomic)
    } catch {
        throw MemorySettingsError.writeFailed(error)
    }
}

func brainHooksAdd(to json: inout [String: Any], hooksDir: String, nodeCmd: String) {
    var hooks = json["hooks"] as? [String: Any] ?? [:]

    let ssEntry: [String: Any] = ["hooks": [["type": "command",
        "command": "\(nodeCmd) \"\(hooksDir)/brain-session-start.js\"",
        "timeout": 8, "statusMessage": "Loading brain context..."]]]
    var ss = hooks["SessionStart"] as? [[String: Any]] ?? []
    ss.insert(ssEntry, at: 0)
    hooks["SessionStart"] = ss

    let upsEntry: [String: Any] = ["hooks": [["type": "command",
        "command": "\(nodeCmd) \"\(hooksDir)/brain-prompt.js\"",
        "timeout": 5]]]
    var ups = hooks["UserPromptSubmit"] as? [[String: Any]] ?? []
    ups.insert(upsEntry, at: 0)
    hooks["UserPromptSubmit"] = ups

    json["hooks"] = hooks
}

func brainHooksRemove(from json: inout [String: Any]) {
    guard var hooks = json["hooks"] as? [String: Any] else { return }
    func clean(_ key: String, term: String) {
        if var arr = hooks[key] as? [[String: Any]] {
            arr.removeAll { group in
                ((group["hooks"] as? [[String: Any]]) ?? []).contains { h in
                    (h["command"] as? String)?.contains(term) == true
                }
            }
            hooks[key] = arr
        }
    }
    clean("SessionStart", term: "brain-session-start")
    clean("UserPromptSubmit", term: "brain-prompt")
    json["hooks"] = hooks
}

func brainMcpAdd(to json: inout [String: Any]) {
    var mcp = json["mcpServers"] as? [String: Any] ?? [:]
    mcp["coucou-brain"] = ["type": "stdio", "command": "brain", "args": ["mcp"]]
    json["mcpServers"] = mcp
}

func brainMcpRemove(from json: inout [String: Any]) {
    guard var mcp = json["mcpServers"] as? [String: Any] else { return }
    mcp.removeValue(forKey: "coucou-brain")
    json["mcpServers"] = mcp
}
