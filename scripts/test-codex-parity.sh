#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d)
trap 'rm -rf "$task_tmp"' EXIT
cat > "$task_tmp/main.swift" <<'SWIFT'
import Foundation
let patch = """
*** Begin Patch
*** Add File: new file.txt
+hello
+world
*** Update File: before.swift
*** Move to: after.swift
-old
+new
*** Delete File: gone.txt
*** End Patch
"""
let files = DiffEngine.fromCodexPatch(patch)
assert(files.count == 3)
assert(files[0].path == "new file.txt" && files[0].added == 2 && files[0].isNewFile)
assert(files[1].path == "after.swift" && files[1].added == 1 && files[1].removed == 1)
assert(files[2].path == "gone.txt" && files[2].removed == 0 && files[2].hunks.isEmpty)
let unified = """
diff --git a/a.swift b/a.swift
--- a/a.swift
+++ b/a.swift
@@ -2,2 +2,2 @@
 old
-removed
+added
diff --git a/b.swift b/b.swift
--- /dev/null
+++ b/b.swift
@@ -0,0 +1,1 @@
+new
"""
let diffs = DiffEngine.fromUnifiedDiff(unified)
assert(diffs.count == 2 && diffs[0].added == 1 && diffs[0].removed == 1)
assert(diffs[0].hunks[0].lines[0].origLine == 2)
assert(diffs[1].isNewFile && diffs[1].added == 1)
let concatenated = """
--- a/a.swift
+++ b/a.swift
@@ -1 +1 @@
-old
+new
--- a/b.swift
+++ b/b.swift
@@ -1 +1 @@
-before
+after
"""
let plainFiles = DiffEngine.fromUnifiedDiff(concatenated)
assert(plainFiles.count == 2 && plainFiles[0].path == "a.swift" && plainFiles[1].path == "b.swift")
assert(plainFiles.allSatisfy { $0.added == 1 && $0.removed == 1 })
let headerLikeContent = """
--- a/content.txt
+++ b/content.txt
@@ -1,2 +1,2 @@
--- old content
+++ new content
 same
"""
let headerLines = DiffEngine.fromUnifiedDiff(headerLikeContent, path: "/chosen/content.txt")
assert(headerLines.count == 1 && headerLines[0].path == "/chosen/content.txt")
assert(headerLines[0].added == 1 && headerLines[0].removed == 1)
assert(headerLines[0].hunks[0].lines[0].text == "-- old content")
assert(headerLines[0].hunks[0].lines[1].text == "++ new content")
let deletion = """
--- a/deleted.txt
+++ /dev/null
@@ -1,2 +0,0 @@
-one
-two
"""
let deleted = DiffEngine.fromUnifiedDiff(deletion, path: "/chosen/deleted.txt")
assert(deleted.count == 1 && deleted[0].path == "/chosen/deleted.txt")
assert(deleted[0].added == 0 && deleted[0].removed == 2)
let zeroLines = "--- /dev/null\n+++ b/empty.txt\n@@ -0,0 +0,0 @@\n"
assert(DiffEngine.fromUnifiedDiff(zeroLines, path: "/chosen/empty.txt").isEmpty)
// The successful native fileChange kind/path supplies zero-line operations;
// a hunk parser cannot invent their contents or counts.
assert(DiffEngine.fromCodexPatch(String(repeating: "x", count: FileDiff.maxBytes + 1)).isEmpty)
let params: [String: Any] = ["threadId":"child", "turnId":"turn", "questions":[
 ["id":"a", "question":"Same?", "header":"A", "options":[["label":"Yes"]], "isOther":false, "isSecret":false],
 ["id":"b", "question":"Same?", "header":"B", "options":NSNull(), "isOther":false, "isSecret":true]]]
let question = AskQuestion.parseCodex(params, requestId: "123")!
let answers = AskQuestion.buildAnswers(questions: question.questions, selections: [["Yes"], ["secret"]])
assert(answers.count == 2 && (answers["a"] as? [String:[String]])?["answers"] == ["Yes"])
assert(question.questions[1].isSecret && question.questions[1].options.isEmpty)
var bad = params
bad["questions"] = [["id":"dup","question":"Q"],["id":"dup","question":"Q"]]
assert(AskQuestion.parseCodex(bad, requestId:"r") == nil)
let claude = AskQuestionItem(question:"Q", header:"Q", options:[], multiSelect:false)
assert(AskQuestion.buildAnswers(questions:[claude], selections:[["A"]])["Q"] as? String == "A")
print("PASS Codex multi-file/move/delete/size bounds and ID-based/secret questions; Claude answers preserved")
SWIFT
python3 - "$task_tmp/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('NotchBuddy/Sources/App/HookServer.swift').read_text()
start = source.index('    private static func codexApprovalRules(')
end = source.index('\n    @MainActor', start)
helpers = source[start:end].replace('private static func', 'static func')
with Path(sys.argv[1]).open('a') as out:
    out.write('\nenum HookServer {\n' + helpers + '\n}\n' + '''
let commandRule: [String: Any] = ["acceptWithExecpolicyAmendment": ["execpolicy_amendment": ["git", "status"]]]
let networkRule: [String: Any] = ["applyNetworkPolicyAmendment": ["network_policy_amendment": ["host": "example.com", "action": "allow"]]]
assert(HookServer.codexApprovalRules(["accept", commandRule, ["unknown": true], networkRule]).count == 2)
assert(HookServer.codexApprovalRules([["acceptWithExecpolicyAmendment": ["execpolicy_amendment": []]]]).isEmpty)
assert(!HookServer.codexPermissionsMayWrite(["network": ["enabled": true]]))
assert(!HookServer.codexPermissionsMayWrite(["fileSystem": ["entries": [["access": "read"]]]]))
assert(HookServer.codexPermissionsMayWrite(["fileSystem": ["write": ["/chosen"]]]))
assert(HookServer.codexPermissionsMayWrite(["fileSystem": ["entries": [["access": "future-write"]]]]))
assert(HookServer.codexPermissionsMayWrite(["futurePermission": true]))
assert(HookServer.codexPermissionsMayWrite(["fileSystem": ["entries": true]]))
print("PASS actual native approval rules and read-only permission escalation guards")
''')
PY
swiftc NotchBuddy/Sources/CoucouKit/DiffEngine.swift NotchBuddy/Sources/App/AskQuestion.swift "$task_tmp/main.swift" -o "$task_tmp/check"
"$task_tmp/check"

# Exercise the actual adapter with in-memory owner/UI boundaries; no Codex,
# CloudKit or inference is started by this fixture.
cat > "$task_tmp/AdapterCheck.swift" <<'SWIFT'
import Foundation

enum BotState { case idle, searching, thinking, working, finished, error, ratelimit }
struct AgentTask {
    var id = "agent_codex"
    var codexManaged = false
    var codexThreadId: String?
    var codexTurnId: String?
    var sessionId: String?
    var sessionCwd: String?
    var state: BotState = .idle
}
@MainActor final class AppState {
    static let shared = AppState()
    var tasks = [AgentTask()]
    var noteMessage = ""
    func updateTask(id: String, state: BotState) {
        if let index = tasks.firstIndex(where: { $0.id == id }) { tasks[index].state = state }
    }
}
@MainActor final class CodexChatService {
    static let shared = CodexChatService()
    var ownedThread = "child"
    func owns(threadId: String) -> Bool { threadId == ownedThread }
}
@MainActor final class CodexConnection {
    static let shared = CodexConnection()
    var observers: [(String, [String: Any], Any?) -> Void] = []
    func observe(_ callback: @escaping (String, [String: Any], Any?) -> Void) -> UUID {
        observers.append(callback); return UUID()
    }
    func emit(_ method: String, _ params: [String: Any], id: Any? = nil) {
        for callback in observers { callback(method, params, id) }
    }
}
@MainActor final class HookServer {
    static let shared = HookServer()
    var events: [(name: String, payload: [String: Any])] = []
    var requests: [String] = []
    var resolutions = 0
    var files: [FileDiff] = []
    func receiveCodexEvent(name: String, payload: [String: Any]) {
        events.append((name, payload))
        var task = AppState.shared.tasks[0]
        task.codexManaged = true; task.codexThreadId = payload["thread_id"] as? String
        task.sessionId = payload["session_id"] as? String; task.sessionCwd = payload["cwd"] as? String
        if let turn = payload["turn_id"] as? String, !turn.isEmpty { task.codexTurnId = turn }
        AppState.shared.tasks[0] = task
    }
    func receiveCodexRequest(method: String, params: [String: Any], id: Any) { requests.append(method) }
    func resolveCodexRequests(threadId: String? = nil, requestId: Any? = nil) { resolutions += 1 }
    func recordCodexDiff(_ diff: FileDiff, sessionId: String) { files.append(diff) }
}
@MainActor final class TurnRecorder {
    static let shared = TurnRecorder()
    var methods: [String] = []
    func recordCodex(method: String, params: [String: Any], diffs: [FileDiff]) {
        // The production adapter must update identity before publishing Phone data.
        if let turn = params["turnId"] as? String {
            assert(AppState.shared.tasks[0].codexTurnId == turn)
        }
        methods.append(method)
    }
}

@main enum AdapterCheck {
    @MainActor static func main() {
        let adapter = CodexEventAdapter.shared
        let connection = CodexConnection.shared
        let server = HookServer.shared
        adapter.start(); adapter.start()
        assert(connection.observers.count == 1)
        adapter.registerThread(["id": "external", "sessionId": "root", "cwd": "/wrong"])
        assert(server.events.isEmpty)
        adapter.registerThread(["id": "child", "sessionId": "root", "cwd": "/chosen", "path": "/chosen/rollout.jsonl"])
        assert(AppState.shared.tasks[0].sessionId == "root")
        assert(AppState.shared.tasks[0].codexThreadId == "child")
        assert(AppState.shared.tasks[0].sessionCwd == "/chosen")
        assert(!adapter.isManagedHookSession("root") && adapter.isManagedHookSession("child"))
        connection.emit("turn/started", ["threadId": "child", "turn": ["id": "t1"]])
        let command: [String: Any] = ["id": "command", "type": "commandExecution", "command": "false", "exitCode": 1, "status": "completed"]
        connection.emit("item/started", ["threadId": "child", "turnId": "t1", "item": command])
        connection.emit("item/completed", ["threadId": "child", "turnId": "t1", "item": command])
        connection.emit("item/completed", ["threadId": "child", "turnId": "t1", "item": command])
        assert(server.events.filter { $0.name == "PostToolUse" }.count == 1)
        assert((server.events.last?.payload["tool_response"] as? [String: Any])?["exit_code"] as? Int == 1)
        let subagent: [String: Any] = ["id": "subagent", "type": "collabAgentToolCall"]
        connection.emit("item/started", ["threadId": "child", "turnId": "t1", "item": subagent])
        connection.emit("item/completed", ["threadId": "child", "turnId": "t1", "item": subagent])
        assert(server.events.contains { $0.name == "SubagentStart" })
        assert(server.events.contains { $0.name == "SubagentStop" })
        let moved: [String: Any] = ["id": "moved", "type": "fileChange", "status": "completed", "changes": [["path": "/chosen/before.swift", "kind": ["type": "update", "move_path": "/chosen/after.swift"], "diff": "--- a/before.swift\n+++ b/after.swift\n@@ -1 +1 @@\n-old\n+new"]]]
        connection.emit("item/completed", ["threadId": "child", "turnId": "t1", "item": moved])
        assert(server.files.last?.path == "/chosen/after.swift")
        let empty: [String: Any] = ["id": "empty", "type": "fileChange", "status": "completed", "changes": [["path": "/chosen/empty.txt", "kind": ["type": "delete"], "diff": ""]]]
        connection.emit("item/completed", ["threadId": "child", "turnId": "t1", "item": empty])
        assert(server.files.last?.path == "/chosen/empty.txt" && server.files.last?.removed == 0)
        assert(server.files.last?.hunks.isEmpty == true)
        connection.emit("item/completed", ["threadId": "child", "turnId": "t1", "item": ["id": "progress", "type": "agentMessage", "phase": "commentary", "text": "Still working"]])
        connection.emit("item/completed", ["threadId": "child", "turnId": "t1", "item": ["id": "answer", "type": "agentMessage", "phase": "final_answer", "text": "Finished answer"]])
        connection.emit("turn/completed", ["threadId": "child", "turn": ["id": "t1", "status": "completed", "items": []]])
        assert(server.events.last?.name == "Stop")
        assert(server.events.last?.payload["last_assistant_message"] as? String == "Finished answer")
        connection.emit("turn/started", ["threadId": "child", "turn": ["id": "t2"]])
        let before = server.events.count
        let resolutions = server.resolutions
        connection.emit("turn/completed", ["threadId": "child", "turn": ["id": "t1", "status": "completed"]])
        assert(server.events.count == before && server.resolutions == resolutions)
        connection.emit("turn/completed", ["threadId": "child", "turn": ["id": "t2", "status": "future_status"]])
        assert(server.events.count == before && AppState.shared.tasks[0].state == .error)
        connection.emit("serverRequest/resolved", ["requestId": 42])
        assert(server.resolutions > resolutions)
        CodexChatService.shared.ownedThread = "different"
        let unchanged = server.events.count
        connection.emit("turn/started", ["threadId": "child", "turn": ["id": "t3"]])
        assert(server.events.count == unchanged && !adapter.isManagedHookSession("root"))
        connection.emit("$connection/disconnected", [:])
        assert(!AppState.shared.tasks[0].codexManaged && AppState.shared.tasks[0].state == .idle)
        print("PASS actual Codex adapter: owner/root/thread/turn identity, Phone ordering, item dedup, subagents, final fallback, unknown status and disconnect")
    }
}
SWIFT
swiftc -swift-version 6 -D PHONE_LINK NotchBuddy/Sources/CoucouKit/DiffEngine.swift \
    NotchBuddy/Sources/App/CodexEventAdapter.swift "$task_tmp/AdapterCheck.swift" -o "$task_tmp/adapter-check"
"$task_tmp/adapter-check"
