#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-phone-codex.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
cat > "$TEST_DIR/main.swift" <<'SWIFT'
import Foundation

let now = Date(timeIntervalSince1970: 1_000_000)
let target = SessionInstructionIdentity.make(pillId: "agent_codex", sessionId: "root", threadId: "child", cwd: "/project/a", turnId: "turn-1")!
let nextTurn = SessionInstructionIdentity.make(pillId: "agent_codex", sessionId: "root", threadId: "child", cwd: "/project/a", turnId: "turn-2")!
let anotherThread = SessionInstructionIdentity.make(pillId: "agent_codex", sessionId: "root", threadId: "other-child", cwd: "/project/a", turnId: "turn-1")!
let anotherProject = SessionInstructionIdentity.make(pillId: "agent_codex", sessionId: "root", threadId: "child", cwd: "/project/b", turnId: "turn-1")!
assert(target != nextTurn && target != anotherThread && target != anotherProject)
let finishedKey = SessionInstructionIdentity.notificationKey(state: "finished", targetIdentity: target, questionFingerprint: "")
assert(finishedKey != SessionInstructionIdentity.notificationKey(state: "finished", targetIdentity: nextTurn, questionFingerprint: ""))
assert(finishedKey == SessionInstructionIdentity.notificationKey(state: "finished", targetIdentity: target, questionFingerprint: ""))
assert(SessionInstructionIdentity.notificationKey(state: "finished", targetIdentity: "", questionFingerprint: "") == "finished")
assert(SessionInstructionIdentity.make(pillId: "agent_codex", sessionId: "root", threadId: nil, cwd: "/project/a") == nil)
assert(SessionInstructionIdentity.make(pillId: "agent_codex", sessionId: "root", threadId: "child", cwd: "relative") == nil)
assert(SessionInstructionIdentity.accepts(target, current: target, createdAt: now, text: "Continue", busy: false, now: now))
assert(!SessionInstructionIdentity.accepts(target, current: nextTurn, createdAt: now, text: "Continue", busy: false, now: now))
assert(!SessionInstructionIdentity.accepts(target, current: nil, createdAt: now, text: "Continue", busy: false, now: now))
assert(!SessionInstructionIdentity.accepts(target, current: target, createdAt: now.addingTimeInterval(-600), text: "Continue", busy: false, now: now))
assert(!SessionInstructionIdentity.accepts(target, current: target, createdAt: now.addingTimeInterval(61), text: "Continue", busy: false, now: now))
assert(!SessionInstructionIdentity.accepts(target, current: target, createdAt: now, text: "Continue", busy: true, now: now))
assert(!SessionInstructionIdentity.accepts(target, current: target, createdAt: now, text: String(repeating: "x", count: 8001), busy: false, now: now))

var question = QuestionPayload(items: [.init(question: "Which?", header: "", options: [.init(label: "A", description: "")], multiSelect: false, id: "q-1", isOther: true, isSecret: false)], pillId: "agent_codex", sessionId: "root", threadId: "child", turnId: "turn-1", requestId: "request-1")
let originalFingerprint = question.fingerprint
assert(question.accepts([["A"]]) && question.accepts([["Custom answer"]]))
assert(!question.accepts([["A", "Custom answer"]]) && !question.accepts([[""]]))
question.requestId = "request-2"
assert(question.fingerprint != originalFingerprint)
question.pillId = "integration_claude"
assert(question.fingerprint != originalFingerprint)
question.items[0].isOther = false
assert(!question.accepts([["Custom answer"]]))
question.items[0].options = []
assert(question.accepts([["Free form"]]))
question.items[0].isSecret = true
assert(question.containsSecret && !question.accepts([["Secret answer"]]))
let legacy = #"{"items":[{"question":"Q?","header":"","options":[{"label":"A","description":""}],"multiSelect":false}]}"#
assert(QuestionPayload.decode(legacy)?.accepts([["A"]]) == true)

let turn = TurnSnapshot(pillId: "agent_codex", sessionId: "root", project: "a", prompt: "", actions: [], files: [], finalMessage: "", startedAt: now, endedAt: nil, threadId: "child", turnId: "turn-1")
let encoded = try JSONEncoder().encode(turn)
let decoded = try JSONDecoder().decode(TurnSnapshot.self, from: encoded)
assert(decoded == turn)
var old = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
old.removeValue(forKey: "threadId"); old.removeValue(forKey: "turnId")
let legacyTurn = try JSONDecoder().decode(TurnSnapshot.self, from: JSONSerialization.data(withJSONObject: old))
assert(legacyTurn.threadId == nil && legacyTurn.turnId == nil)
print("PASS: Phone target identity, expiry, busy rejection, native request binding, secret exclusion and legacy decoding")
SWIFT
swiftc NotchBuddy/Sources/CoucouKit/DiffEngine.swift \
    NotchBuddy/Sources/CoucouKit/TurnSnapshot.swift \
    NotchBuddy/Sources/CoucouKit/QuestionPayload.swift \
    "$TEST_DIR/main.swift" -o "$TEST_DIR/phone-codex-check"
"$TEST_DIR/phone-codex-check"

# State fixtures only: compile and exercise the actual recorder without
# initializing CloudKit, running a turn, or claiming device acceptance.
cat > "$TEST_DIR/RecorderCheck.swift" <<'SWIFT'
import AppKit
import CloudKit

struct AgentTask { var id:String; var codexManaged:Bool; var codexThreadId:String?; var sessionId:String?; var sessionCwd:String? }
@MainActor final class AppState { static let shared = AppState(); var tasks:[AgentTask] = [] }
enum PillCatalog { static func isSession(_ id:String) -> Bool { true } }
@MainActor final class CloudProbe { nonisolated static let containerID = "iCloud.fr.louisraille.Coucou"; static let shared = CloudProbe(); func log(_ message:String) {} }
enum SessionSnapshot { static var zoneID:CKRecordZone.ID { .init(zoneName:"Coucou", ownerName:CKCurrentUserDefaultName) } }

@main enum RecorderCheck {
    @MainActor static func main() {
        let recorder = TurnRecorder.shared
        AppState.shared.tasks = [.init(id:"agent_codex", codexManaged:true, codexThreadId:"child", sessionId:"root", sessionCwd:"/project/a")]
        recorder.start()
        func turns() -> [String:TurnSnapshot] { Mirror(reflecting:recorder).children.first(where: { $0.label == "turns" })!.value as! [String:TurnSnapshot] }
        recorder.recordCodex(method:"turn/started", params:["threadId":"child", "turn":["id":"t1"]])
        assert(turns()["agent_codex"]?.sessionId == "root")
        assert(turns()["agent_codex"]?.threadId == "child")
        recorder.recordCodex(method:"item/completed", params:["threadId":"other", "turnId":"t1", "item":["id":"p", "type":"userMessage", "content":[["text":"Wrong"]]]])
        assert(turns()["agent_codex"]?.prompt == "")
        recorder.recordCodex(method:"item/completed", params:["threadId":"child", "turnId":"t1", "item":["id":"p", "type":"userMessage", "content":[["text":"Fix it"]]]])
        assert(turns()["agent_codex"]?.prompt == "Fix it")
        recorder.recordCodex(method:"item/completed", params:["threadId":"child", "turnId":"t1", "item":["id":"progress", "type":"agentMessage", "phase":"commentary", "text":"Working on it"]])
        assert(turns()["agent_codex"]?.finalMessage == "")
        let item:[String:Any] = ["id":"cmd", "type":"commandExecution", "command":"false", "exitCode":1, "aggregatedOutput":"failed"]
        recorder.recordCodex(method:"item/started", params:["threadId":"child", "turnId":"t1", "item":item])
        recorder.recordCodex(method:"item/completed", params:["threadId":"child", "turnId":"t1", "item":item])
        recorder.recordCodex(method:"item/completed", params:["threadId":"child", "turnId":"t1", "item":item])
        assert(turns()["agent_codex"]?.actions.count == 1)
        assert(turns()["agent_codex"]?.actions.first?.failed == true)
        assert(turns()["agent_codex"]?.actions.first?.output == "failed")
        let patch = "*** Begin Patch\n*** Add File: a.swift\n+let a = 1\n*** End Patch"
        let diffs = DiffEngine.fromCodexPatch(patch)
        let file:[String:Any] = ["id":"file", "type":"fileChange", "status":"completed", "changes":[["path":"a.swift"]]]
        recorder.recordCodex(method:"item/completed", params:["threadId":"child", "turnId":"t1", "item":file], diffs:diffs)
        recorder.recordCodex(method:"turn/diff/updated", params:["threadId":"child", "turnId":"t1"], diffs:diffs)
        recorder.recordCodex(method:"turn/diff/updated", params:["threadId":"child", "turnId":"t1"], diffs:diffs)
        assert(turns()["agent_codex"]?.files.count == 1)
        let movedDiff = DiffEngine.fromUnifiedDiff("--- a/before.swift\n+++ b/after.swift\n@@ -1 +1 @@\n-old\n+new", path: "/chosen/after.swift")
        let moved:[String:Any] = ["id":"moved", "type":"fileChange", "status":"completed", "changes":[["path":"/chosen/before.swift", "kind":["type":"update", "move_path":"/chosen/after.swift"]]]]
        recorder.recordCodex(method:"item/completed", params:["threadId":"child", "turnId":"t1", "item":moved], diffs:movedDiff)
        assert(turns()["agent_codex"]?.actions.last?.summary == "/chosen/after.swift")
        recorder.recordCodex(method:"turn/diff/updated", params:["threadId":"child", "turnId":"t1"], diffs:movedDiff)
        assert(turns()["agent_codex"]?.actions.last?.fileIndex == 0)
        recorder.recordCodex(method:"turn/completed", params:["threadId":"child", "turn":["id":"t1", "error":["message":"Quota exhausted"]]])
        assert(turns()["agent_codex"]?.endedAt != nil)
        assert(turns()["agent_codex"]?.finalMessage == "Quota exhausted")
        assert(TurnRecorder.commandFailed(["tool_response":["exit_code":1]]))
        print("PASS: actual native TurnRecorder source, target checks, command failure, item dedup and cumulative diff")
    }
}
SWIFT
swiftc -swift-version 6 -D PHONE_LINK NotchBuddy/Sources/CoucouKit/DiffEngine.swift \
    NotchBuddy/Sources/CoucouKit/TurnSnapshot.swift \
    NotchBuddy/Sources/App/PhoneLink/TurnRecorder.swift \
    "$TEST_DIR/RecorderCheck.swift" -o "$TEST_DIR/recorder-check"
"$TEST_DIR/recorder-check"

# The actual SessionSnapshot must preserve the notification target across
# busy transitions while its instruction capability stays independently gated.
cat > "$TEST_DIR/SnapshotCheck.swift" <<'SWIFT'
import AppKit
import CloudKit
import Combine

struct AgentTask { var id:String; var codexManaged:Bool; var codexThreadId:String?; var codexTurnId:String?; var sessionId:String?; var sessionCwd:String?; var state:BotState; var source:TaskSource; var name:String; var color:String; var stepIndex:Int; var steps:[String]; var finalLine:String? }
enum BotState:String { case idle,finished,sleeping,error,ratelimit,question,working }
enum TaskSource { case n8n,workspace }
struct ApprovalInfo:Sendable { var pillId:String; var sessionId:String; var threadId:String?; var turnId:String?; var requestId:String?; var tool:String; var command:String; var inputKey:String }
@MainActor final class AppState { static let shared = AppState(); @Published var codexChatBusy = false; @Published var tasks:[AgentTask] = []; @Published var pendingApproval:ApprovalInfo?; @Published var pendingQuestion:AskQuestion? }
enum PillCatalog { static func isSession(_ id:String) -> Bool { true } }
@MainActor final class CloudProbe { nonisolated static let containerID = "iCloud.fr.louisraille.Coucou"; static let shared = CloudProbe(); static let isEnabled = false; static var zoneID:CKRecordZone.ID { .init(zoneName:"Coucou", ownerName:CKCurrentUserDefaultName) }; func log(_ message:String) {} }
@MainActor final class CodexChatService { static let shared = CodexChatService(); var isBusy = false; func owns(threadId:String)->Bool { true }; func sendManagedInstruction(threadId:String,text:String,expectedCwd:String) async throws {} }
@MainActor final class HookServer { static let shared = HookServer(); var hasRealPendingQuestion=true; func sendQuestionAnswers(_ answers:[String:Any]) {}; func sendApprovalDecision(_ decision:String) {} }
@MainActor final class DemoEngine { static let shared = DemoEngine(); var isActive=false }

@main enum SnapshotCheck {
    @MainActor static func main() {
        UserDefaults.standard.register(defaults: [InstructionRunner.enabledKey: true])
        var task = AgentTask(id: "agent_codex", codexManaged: true, codexThreadId: "child", codexTurnId: "t1", sessionId: "root", sessionCwd: "/chosen", state: .finished, source: .workspace, name: "project", color: "#ffffff", stepIndex: 0, steps: [], finalLine: "done")
        let finished = SessionSnapshot.all(tasks: [task], approval: nil, question: nil)[task.id]!
        assert(!finished.instructionTargetIdentity.isEmpty)
        CodexChatService.shared.isBusy = true
        let cleanupPending = SessionSnapshot.all(tasks: [task], approval: nil, question: nil)[task.id]!
        assert(cleanupPending.instructionTargetIdentity == finished.instructionTargetIdentity && !cleanupPending.acceptsInstructions)
        task.state = .working
        let busy = SessionSnapshot.all(tasks: [task], approval: nil, question: nil)[task.id]!
        assert(busy.instructionTargetIdentity == finished.instructionTargetIdentity && !busy.acceptsInstructions)
        task.codexTurnId = "t2"
        let next = SessionSnapshot.all(tasks: [task], approval: nil, question: nil)[task.id]!
        assert(next.instructionTargetIdentity != busy.instructionTargetIdentity)
        task.state = .question
        let secret = AskQuestion(questions: [.init(question: "Sensitive prompt", header: "", options: [], multiSelect: false, id: "q", isOther: false, isSecret: true)], pillId: task.id, threadId: "child", turnId: "t2", requestId: "secret")
        let hidden = SessionSnapshot.all(tasks: [task], approval: nil, question: secret)[task.id]!
        assert(hidden.question.isEmpty && hidden.questionPayload.isEmpty && hidden.questionFingerprint.isEmpty)
        print("PASS: actual SessionSnapshot stable target, independent busy gate, next-turn identity and secret omission")
    }
}
SWIFT
swiftc -swift-version 6 -D PHONE_LINK NotchBuddy/Sources/CoucouKit/DiffEngine.swift \
    NotchBuddy/Sources/CoucouKit/TurnSnapshot.swift NotchBuddy/Sources/CoucouKit/QuestionPayload.swift \
    NotchBuddy/Sources/App/AskQuestion.swift NotchBuddy/Sources/App/PhoneLink/TurnRecorder.swift \
    NotchBuddy/Sources/App/PhoneLink/InstructionRunner.swift NotchBuddy/Sources/App/PhoneLink/SessionPublisher.swift \
    NotchBuddy/Sources/App/PhoneLink/ApprovalRelay.swift NotchBuddy/Sources/App/PhoneLink/QuestionRelay.swift \
    "$TEST_DIR/SnapshotCheck.swift" -o "$TEST_DIR/snapshot-check"
"$TEST_DIR/snapshot-check"
