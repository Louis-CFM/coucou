import Foundation

// Same cases as the Linux tests in windows/src-tauri/src/claude_code.rs.
@main
struct ClaudeCodeChatTests {
    static func main() {
        var failures = 0
        func check(_ cond: Bool, _ msg: String) {
            if cond { print("✓ \(msg)") } else { print("✗ \(msg)"); failures += 1 }
        }

        // Lines as `claude -p --output-format stream-json --verbose --include-partial-messages` 2.1.296 writes them.
        let sample = [
            #"{"type":"system","subtype":"init","cwd":"/x","session_id":"ff0b3fc3-cf07-4a7d-8081-484fc71bedad","tools":["Bash"]}"#,
            #"{"type":"system","subtype":"status","status":"requesting","session_id":"ff0b"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}},"session_id":"ff0b"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi there"}},"session_id":"ff0b"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"!"}},"session_id":"ff0b"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Hi there!"}]},"session_id":"ff0b"}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"Hi there!","session_id":"ff0b3fc3-cf07-4a7d-8081-484fc71bedad"}"#,
        ]
        let parsed = sample.map(ClaudeCodeChat.parse)
        check(parsed[0] == .session("ff0b3fc3-cf07-4a7d-8081-484fc71bedad"), "init gives the session")
        check(parsed[1] == .other, "status lines are ignored")
        check(parsed[2] == .block, "a text block start is a paragraph break")
        check(parsed[3] == .text("Hi there") && parsed[4] == .text("!"), "text deltas stream")
        check(parsed[5] == .other, "the whole assistant message is not counted twice")
        check(parsed[6] == .done(error: nil, result: "Hi there!"), "the result ends the turn")
        check(ClaudeCodeChat.parse("not json") == .other, "junk is ignored")

        let failed = #"{"type":"result","subtype":"success","is_error":true,"result":"Invalid API key · Please run /login"}"#
        check(ClaudeCodeChat.parse(failed) == .done(error: "Invalid API key · Please run /login", result: "Invalid API key · Please run /login"),
              "a failed turn says why in Claude Code's words")
        let maxTurns = #"{"type":"result","subtype":"error_max_turns","is_error":false}"#
        check(ClaudeCodeChat.parse(maxTurns) == .done(error: "error_max_turns", result: ""), "a failed subtype is an error")

        let a = ClaudeCodeChat.arguments(systemPrompt: "p", model: "opus", effort: "high", resume: "abc", extraDir: nil)
        func has(_ args: [String], _ flag: String, _ value: String) -> Bool {
            zip(args, args.dropFirst()).contains { $0 == flag && $1 == value }
        }
        check(has(a, "--model", "opus") && has(a, "--effort", "high") && has(a, "--resume", "abc"), "model, effort and session reach the command line")
        let b = ClaudeCodeChat.arguments(systemPrompt: "p", model: "default", effort: "", resume: nil, extraDir: nil)
        check(!b.contains("--model") && !b.contains("--effort") && !b.contains("--resume"), "defaults leave the flags off")
        let c = ClaudeCodeChat.arguments(systemPrompt: "p", model: "--dangerously-skip-permissions", effort: "--x", resume: nil, extraDir: nil)
        check(!c.contains("--dangerously-skip-permissions") && !c.contains("--x"), "only known models and efforts get through")

        check(ClaudeCodeChat.question(first: false, resuming: true, earlier: [], context: nil, query: "next") == "next",
              "a resumed session gets the question alone")
        check(ClaudeCodeChat.question(first: false, resuming: false, earlier: [(true, "q"), (false, "a")], context: nil, query: "next")
              == "Earlier in this conversation:\nUser: q\nAssistant: a\n\nnext", "another provider's turns come along")
        check(ClaudeCodeChat.question(first: true, resuming: false, earlier: [], context: "File: a.txt (/in/a.txt)", query: "read it")
              == "File: a.txt (/in/a.txt)\n\nread it", "the dropped file goes with the first turn")
        check(ClaudeCodeChat.label(model: "default", effort: "") == "Claude Code"
              && ClaudeCodeChat.label(model: "opus", effort: "high") == "opus · high", "the model button reads model · effort")

        if failures > 0 { print("\(failures) failure(s)"); exit(1) }
        print("All Claude Code chat tests passed")
    }
}
