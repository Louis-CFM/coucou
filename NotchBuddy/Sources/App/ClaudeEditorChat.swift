import Foundation

/// A Claude Code session in the VS Code extension's chat panel, for "Open terminal": the
/// extension opens (or focuses) that session's tab from
/// `vscode://anthropic.claude-code/open?session=<id>`.
/// Foundation only, so it can be tested without AppKit (see scripts/test-claude-editor-chat.sh).
enum ClaudeEditorChat {
    /// Editors whose URL scheme reaches the Claude Code extension, by lowercased bundle id.
    static let schemes: [String: String] = [
        "com.microsoft.vscode": "vscode",
        "com.microsoft.vscodeinsiders": "vscode-insiders",
    ]

    /// True for a session in the extension's chat panel. VS Code's integrated terminal sets
    /// TERM_PROGRAM=vscode; the extension runs Claude Code with no TERM_PROGRAM at all, so a
    /// session in a terminal inside VS Code still goes back to the editor window only.
    static func isExtensionChat(termProgram: String, bundleId: String) -> Bool {
        termProgram.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && schemes[bundleId.lowercased()] != nil
    }

    /// The link that opens the session's chat tab, or nil when the editor or the id won't do.
    static func url(sessionId: String, bundleId: String) -> URL? {
        guard let scheme = schemes[bundleId.lowercased()], isSessionId(sessionId) else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "anthropic.claude-code"
        components.path = "/open"
        components.queryItems = [URLQueryItem(name: "session", value: sessionId)]
        return components.url
    }

    /// Claude Code session ids are UUIDs; accept ASCII letters, digits, "-" and "_" only.
    static func isSessionId(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128, id != "unknown" else { return false }
        return id.unicodeScalars.allSatisfy { s in
            ("a"..."z").contains(s) || ("A"..."Z").contains(s) || ("0"..."9").contains(s)
                || s == "-" || s == "_"
        }
    }
}
