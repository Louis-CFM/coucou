import Foundation

@main
enum ClaudeDesktopChatTests {
    static var failures = 0
    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") } else { print("  ✗ \(label)"); failures += 1 }
    }

    static func main() {
        print("\nClaude Desktop: the stop button")
        check("Stop response", ClaudeDesktopChat.isStopLabel(["Stop response"]))
        check("in the title, not the description", ClaudeDesktopChat.isStopLabel([nil, "Stop response", nil]))
        check("spaces and case", ClaudeDesktopChat.isStopLabel(["  STOP RESPONSE "]))
        check("French", ClaudeDesktopChat.isStopLabel(["Arrêter la réponse"]))
        check("Japanese", ClaudeDesktopChat.isStopLabel(["応答を停止"]))
        check("Stop responding", ClaudeDesktopChat.isStopLabel(["Stop responding"]))
        check("not the send button", !ClaudeDesktopChat.isStopLabel(["Send message"]))
        check("not stop recording", !ClaudeDesktopChat.isStopLabel(["Stop recording"]))
        check("not a lone Stop", !ClaudeDesktopChat.isStopLabel(["Stop"]))
        check("nothing", !ClaudeDesktopChat.isStopLabel([nil, "", nil]))
        if failures > 0 { print("\n\(failures) failure(s)"); exit(1) }
        print("\nAll Claude Desktop chat tests passed")
    }
}
