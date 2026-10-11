import Foundation

@main
struct RemoteTrustTests {
    static func main() {
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            if ok { print("  ✓ \(name)") } else { print("  ✗ \(name)"); failures += 1 }
        }

        // A remote host's event keeps only what a host may say
        let event: [String: Any] = [
            "hook_event_name": "PreToolUse", "session_id": "0f8fad5b-d9cb-469f-a165-70867728950e",
            "coucou_agent": "codex", "coucou_has_transport": true, "coucou_remote": "spoofed",
            "term_program": "iTerm.app", "bundle_id": "com.apple.Terminal",
        ]
        let admitted = RemoteEvent.admit(event, host: "devbox")
        check(admitted?["coucou_remote"] as? String == "devbox", "tagged with its host")
        check(admitted?["coucou_agent"] == nil && admitted?["coucou_has_transport"] == nil, "relay fields dropped")
        check(admitted?["term_program"] == nil && admitted?["bundle_id"] == nil, "terminal fields dropped")
        check(admitted?["hook_event_name"] as? String == "PreToolUse", "the event itself kept")

        var question = event
        question["coucou_kind"] = "ask_user_question"
        check(RemoteEvent.admit(question, host: "devbox")?["coucou_kind"] as? String == "ask_user_question",
              "a question keeps its kind")
        var status = event
        status["coucou_kind"] = "statusline"
        check(RemoteEvent.admit(status, host: "devbox") == nil, "a status line from a host is dropped")
        var long = event
        long["session_id"] = String(repeating: "x", count: RemoteEvent.maxSessionId + 1)
        check(RemoteEvent.admit(long, host: "devbox") == nil, "an oversized session id is dropped")

        // Only a UUID ever reaches `claude --resume`
        check(ClaudeSessionId.valid("0f8fad5b-d9cb-469f-a165-70867728950e"), "a UUID is a session id")
        check(!ClaudeSessionId.valid("--settings={}"), "an option is not")
        check(!ClaudeSessionId.valid(""), "empty is not")
        check(!ClaudeSessionId.valid("0f8fad5bd9cb469fa16570867728950e"), "a bare hex string is not")

        // Only an absolute path to an existing regular file is opened
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("remote-trust-\(getpid())")
        try? FileManager.default.removeItem(at: dir)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("a.ts")
        try! "x".write(to: file, atomically: true, encoding: .utf8)
        check(LocalFile.regular(file.path) != nil, "an existing file opens")
        check(LocalFile.regular("--install-extension=evil.ext") == nil, "an option never opens")
        check(LocalFile.regular("a.ts") == nil, "a relative path never opens")
        check(LocalFile.regular(dir.path) == nil, "a folder never opens")
        check(LocalFile.regular(dir.appendingPathComponent("missing").path) == nil, "a missing file never opens")
        let app = dir.appendingPathComponent("Evil.app")
        try! FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        check(LocalFile.regular(app.path) == nil, "an app bundle never opens")
        try? FileManager.default.removeItem(at: dir)

        if failures > 0 { print("\(failures) failure(s)"); exit(1) }
        print("RemoteTrust: all passed")
    }
}
