import Foundation

/// An opt-in hook config, separate from Claude settings and Anthropic chat.
struct CodexHooks {
    struct Preview {
        let original: Data?
        let replacement: Data
        let diff: String
        let target: URL
        let install: Bool
    }

    let directory: URL
    let relayCommand: String
    var target: URL { directory.appendingPathComponent("hooks.json") }

    static var defaultDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    static let events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse",
                         "PostToolUse", "PermissionRequest", "Stop", "Interrupt",
                         "SubagentStart", "SubagentStop"]
    static let marker = "Coucou Codex"

    private func read() throws -> Data? {
        do { return try Data(contentsOf: target) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
    }

    private func parse(_ bytes: Data?) throws -> [String: Any] {
        guard var data = bytes, !data.isEmpty else { return [:] }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }
        if String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { return [:] }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw failure("hooks.json must be a JSON object")
        }
        if let value = root["hooks"] {
            guard let hooks = value as? [String: Any] else { throw failure("hooks must be an object") }
            for (event, value) in hooks {
                guard let groups = value as? [[String: Any]], groups.allSatisfy({ $0["hooks"] is [[String: Any]] }) else {
                    throw failure("Invalid hook groups for \(event)")
                }
            }
        }
        return root
    }

    private func isOurs(_ handler: [String: Any]) -> Bool {
        handler["statusMessage"] as? String == Self.marker &&
        (handler["command"] as? String)?.contains(" --codex") == true
    }

    private func clean(_ groups: [[String: Any]]) -> [[String: Any]] {
        groups.compactMap { group in
            guard let handlers = group["hooks"] as? [[String: Any]], handlers.contains(where: isOurs) else { return group }
            let kept = handlers.filter { !isOurs($0) }
            guard !kept.isEmpty else { return nil }
            var out = group
            out["hooks"] = kept
            return out
        }
    }

    var isInstalled: Bool {
        guard let root = try? parse(read()), let hooks = root["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            (value as? [[String: Any]])?.contains { group in
                (group["hooks"] as? [[String: Any]])?.contains(where: isOurs) == true
            } == true
        }
    }

    func preview(install: Bool) throws -> Preview {
        let bytes = try read()
        var root = try parse(bytes)
        let before = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in Array(hooks.keys) {
            let groups = clean(hooks[event] as? [[String: Any]] ?? [])
            if groups.isEmpty && !(hooks[event] as? [[String: Any]] ?? []).isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }
        if install {
            for event in Self.events {
                var groups = hooks[event] as? [[String: Any]] ?? []
                groups.append(["hooks": [["type": "command", "command": relayCommand,
                                          "statusMessage": Self.marker,
                                          "timeout": event == "PermissionRequest" ? 120 : ["Interrupt", "SessionEnd"].contains(event) ? 3 : 10]]])
                hooks[event] = groups
            }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        var after = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        after.append(0x0A)
        let diff = "BEFORE\n\(String(decoding: before, as: UTF8.self))\n\nAFTER\n\(String(decoding: after, as: UTF8.self))"
        return Preview(original: bytes, replacement: after, diff: diff, target: target, install: install)
    }

    /// Only called after the user confirms the preview. Backups preserve every byte.
    func apply(_ preview: Preview) throws -> URL? {
        guard preview.target == target, try read() == preview.original else {
            throw failure("hooks.json changed since preview; review a new preview")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var backup: URL?
        if let original = preview.original {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let url = directory.appendingPathComponent("hooks.json.bak-\(formatter.string(from: Date()))-\(UUID().uuidString)")
            try original.write(to: url, options: .withoutOverwriting)
            backup = url
        }
        try preview.replacement.write(to: target, options: .atomic)
        return backup
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "Coucou.CodexHooks", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
