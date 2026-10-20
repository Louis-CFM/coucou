import Foundation

@main
struct ClaudeEditorChatTests {
    static func main() {
        var failures = 0
        func check(_ cond: Bool, _ msg: String) {
            if cond { print("✓ \(msg)") } else { print("✗ \(msg)"); failures += 1 }
        }
        let id = "3f2b8c1e-9a4d-4e5f-8b6a-1c2d3e4f5a6b"

        // The extension's chat panel: VS Code bundle id, no TERM_PROGRAM
        check(ClaudeEditorChat.isExtensionChat(termProgram: "", bundleId: "com.microsoft.VSCode"),
              "VS Code with no TERM_PROGRAM is the extension's chat")
        check(ClaudeEditorChat.isExtensionChat(termProgram: "  ", bundleId: "com.microsoft.VSCodeInsiders"),
              "VS Code Insiders counts too")
        // A terminal inside VS Code is not a chat tab
        check(!ClaudeEditorChat.isExtensionChat(termProgram: "vscode", bundleId: "com.microsoft.VSCode"),
              "VS Code's integrated terminal is not the chat panel")
        check(!ClaudeEditorChat.isExtensionChat(termProgram: "", bundleId: "com.todesktop.230313mzl4w4u92"),
              "Cursor is left as it was")
        check(!ClaudeEditorChat.isExtensionChat(termProgram: "", bundleId: ""),
              "no bundle id is not a chat")

        // The link
        check(ClaudeEditorChat.url(sessionId: id, bundleId: "com.microsoft.VSCode")?.absoluteString
              == "vscode://anthropic.claude-code/open?session=\(id)",
              "VS Code link opens the session's tab")
        check(ClaudeEditorChat.url(sessionId: id, bundleId: "com.microsoft.VSCodeInsiders")?.scheme
              == "vscode-insiders",
              "Insiders gets its own scheme")
        check(ClaudeEditorChat.url(sessionId: id, bundleId: "com.apple.Terminal") == nil,
              "no link for another app")
        check(ClaudeEditorChat.url(sessionId: "unknown", bundleId: "com.microsoft.VSCode") == nil,
              "the placeholder id gives no link")
        check(ClaudeEditorChat.url(sessionId: "", bundleId: "com.microsoft.VSCode") == nil,
              "an empty id gives no link")
        check(ClaudeEditorChat.url(sessionId: "a&prompt=rm -rf", bundleId: "com.microsoft.VSCode") == nil,
              "an id that would add a query item is refused")
        check(ClaudeEditorChat.url(sessionId: "é", bundleId: "com.microsoft.VSCode") == nil,
              "non-ASCII ids are refused")

        if failures > 0 { print("\(failures) failure(s)"); exit(1) }
        print("All ClaudeEditorChat checks passed")
    }
}
