import Foundation

/// What the Mac takes from an event that came through a remote host's tunnel.
/// The host is less trusted than this Mac: it never speaks for a local terminal,
/// a local agent's pill or the plan gauge.
enum RemoteEvent {
    /// Claude Code's ids are UUIDs: a longer one is not a session.
    static let maxSessionId = 128

    private static let terminalFields: Set<String> = ["term_program", "iterm_session_id", "term_session_id", "bundle_id"]

    /// `payload` as the Mac uses it, tagged with `host`; nil when it is dropped.
    static func admit(_ payload: [String: Any], host: String) -> [String: Any]? {
        if let id = payload["session_id"] as? String, id.count > maxSessionId { return nil }
        let kind = payload["coucou_kind"] as? String
        if kind == "statusline" { return nil }

        var admitted = payload.filter { !terminalFields.contains($0.key) && !$0.key.hasPrefix("coucou_") }
        // The host's --ask hook: the one relay field a host may set.
        if kind == "ask_user_question" { admitted["coucou_kind"] = kind }
        admitted["coucou_remote"] = host
        return admitted
    }
}

enum ClaudeSessionId {
    /// Claude Code session ids are UUIDs: nothing else is ever passed to `claude`.
    static func valid(_ id: String) -> Bool {
        id.count == 36 && UUID(uuidString: id) != nil
    }
}

enum LocalFile {
    /// The file `path` names when it is an absolute path to an existing regular
    /// file, links resolved: never something a command could read as an option.
    static func regular(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: resolved),
              attrs[.type] as? FileAttributeType == .typeRegular else { return nil }
        return resolved
    }
}
