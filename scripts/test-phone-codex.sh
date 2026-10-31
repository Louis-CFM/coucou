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
assert(SessionInstructionIdentity.make(pillId: "agent_codex#2", sessionId: "root", threadId: nil, cwd: "/project/a") == nil)
assert(SessionInstructionIdentity.make(pillId: "agent_codex#2", sessionId: "root", threadId: "child", cwd: "/project/a") != nil)
assert(SessionInstructionIdentity.make(pillId: "integration_claude#q2", sessionId: "root", threadId: nil, cwd: "/project/a") == nil)
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
python3 - "$TEST_DIR/main.swift" <<'PYDETAIL'
from pathlib import Path
import sys
source = Path('NotchBuddy/Sources/Phone/SessionDetailView.swift').read_text()
start = source.index('    private var session: SessionItem?')
end = source.index('    private var pastTurns:', start)
properties = source[start:end].replace('private var', 'var')
with Path(sys.argv[1]).open('a') as out:
    out.write('\nstruct SessionItem { var id:String; var cwd:String; var instructionTargetIdentity:String }\n')
    out.write('struct DetailLinkFixture { var sessions:[SessionItem]; var turns:[String:TurnSnapshot] }\n')
    out.write('struct DetailViewFixture { let link:DetailLinkFixture; let sessionId:String;\n'+properties+'}\n')
    out.write('''let currentIdentity=SessionInstructionIdentity.make(pillId:"agent_codex",sessionId:"root",threadId:"child",cwd:"/project/a",turnId:"turn-1")!
func detail(_ identity:String, cwd:String="/project/a", pill:String="agent_codex", snapshot:TurnSnapshot=turn)->TurnSnapshot? {
 DetailViewFixture(link:.init(sessions:[.init(id:pill,cwd:cwd,instructionTargetIdentity:identity)],turns:[pill:snapshot]),sessionId:pill).turn
}
assert(detail(currentIdentity) != nil)
assert(detail(nextTurn) == nil)
assert(detail(anotherThread) == nil)
assert(detail(currentIdentity,cwd:"/different-project") == nil)
assert(detail("different-external-session") == nil)
let poppedIdentity=SessionInstructionIdentity.make(pillId:"agent_codex#2",sessionId:"root",threadId:"child",cwd:"/project/a",turnId:"turn-1")!
assert(detail(poppedIdentity,pill:"agent_codex#2") != nil)
assert(detail(currentIdentity,pill:"agent_codex#q2") == nil)
var legacySnapshot=turn; legacySnapshot.threadId=nil; legacySnapshot.turnId=nil
assert(detail("",snapshot:legacySnapshot) != nil)
print("PASS: actual phone detail property rejects cached native turns for another row owner/thread/turn/project")
''')
PYDETAIL
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

struct AgentTask { var id:String; var codexManaged:Bool; var codexThreadId:String?; var codexTurnId:String?; var sessionId:String?; var sessionCwd:String? }
@MainActor final class AppState { static let shared = AppState(); var tasks:[AgentTask] = [] }
enum PillCatalog { static func isSession(_ id:String) -> Bool { true }; static func basePillId(_ id:String)->String { String(id.split(separator:"#",maxSplits:1)[0]) } }
@MainActor final class CloudProbe { nonisolated static let containerID = "iCloud.fr.louisraille.Coucou"; static let shared = CloudProbe(); func log(_ message:String) {} }
enum SessionSnapshot { static var zoneID:CKRecordZone.ID { .init(zoneName:"Coucou", ownerName:CKCurrentUserDefaultName) } }

@main enum RecorderCheck {
    @MainActor static func main() {
        let recorder = TurnRecorder.shared
        AppState.shared.tasks = [.init(id:"agent_codex", codexManaged:true, codexThreadId:"child", codexTurnId:"t1", sessionId:"root", sessionCwd:"/project/a")]
        recorder.start()
        func turns() -> [String:TurnSnapshot] { Mirror(reflecting:recorder).children.first(where: { $0.label == "turns" })!.value as! [String:TurnSnapshot] }
        recorder.recordCodex(method:"turn/started", params:["threadId":"child", "turn":["id":"t1"]])
        assert(turns()["agent_codex"]?.sessionId == "root")
        assert(turns()["agent_codex"]?.threadId == "child")
        recorder.recordCodex(method:"item/completed", params:["threadId":"other", "turnId":"t1", "item":["id":"p", "type":"userMessage", "content":[["text":"Wrong"]]]])
        assert(turns()["agent_codex"]?.prompt == "")
        recorder.recordCodex(method:"item/completed", params:["threadId":"child", "turnId":"t1", "item":["id":"p", "type":"userMessage", "content":[["text":"Fix it"]]]])
        assert(turns()["agent_codex"]?.prompt == "Fix it")
        AppState.shared.tasks[0].id = "agent_codex#2"
        recorder.recordCodex(method:"item/completed", params:["threadId":"child", "turnId":"t1", "item":["id":"row", "type":"agentMessage", "text":"Popped"]])
        assert(turns()["agent_codex#2"]?.prompt == "Fix it" && turns()["agent_codex#2"]?.finalMessage == "Popped")
        assert(turns()["agent_codex#2"]?.pillId == "agent_codex#2" && turns()["agent_codex"] == nil)
        recorder.record(event:"Stop", payload:["session_id":"root","cwd":"/project/a","last_assistant_message":"Duplicate hook"],pillId:"agent_codex#2")
        assert(turns()["agent_codex#2"]?.finalMessage == "Popped")
        AppState.shared.tasks[0].id = "agent_codex"
        recorder.recordCodex(method:"item/completed", params:["threadId":"child", "turnId":"t1", "item":["id":"fold", "type":"agentMessage", "text":"Folded"]])
        assert(turns()["agent_codex"]?.finalMessage == "Popped\nFolded" && turns()["agent_codex#2"] == nil)
        AppState.shared.tasks[0].codexTurnId = "new-turn"
        recorder.recordCodex(method:"item/completed", params:["threadId":"child", "turnId":"t1", "item":["id":"stale", "type":"agentMessage", "text":"Wrong turn"]])
        assert(turns()["agent_codex"]?.finalMessage == "Popped\nFolded" && turns()["agent_codex#2"] == nil)
        AppState.shared.tasks[0].codexTurnId = "t1"

        recorder.recordCodex(method:"item/completed", params:["threadId":"child", "turnId":"t1", "item":["id":"progress", "type":"agentMessage", "phase":"commentary", "text":"Working on it"]])
        assert(turns()["agent_codex"]?.finalMessage == "Popped\nFolded" && turns()["agent_codex#2"] == nil)
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
        AppState.shared.tasks[0].id = "agent_codex#2"
        AppState.shared.tasks[0].codexTurnId = "t2"
        recorder.recordCodex(method:"turn/started", params:["threadId":"child", "turn":["id":"t2"]])
        assert(turns()["agent_codex"]?.turnId == "t1" && turns()["agent_codex#2"]?.turnId == "t2")
        recorder.record(event:"UserPromptSubmit", payload:["session_id":"external", "cwd":"/project/b", "prompt":"External work"], pillId:"agent_codex")
        assert(turns()["agent_codex"]?.sessionId == "external")
        AppState.shared.tasks[0].id = "agent_codex#3"
        recorder.recordCodex(method:"item/completed", params:["threadId":"child", "turnId":"t2", "item":["id":"moved-again", "type":"agentMessage", "text":"Still native"]])
        assert(turns()["agent_codex#2"] == nil && turns()["agent_codex#3"]?.turnId == "t2")
        assert(turns()["agent_codex#3"]?.finalMessage == "Still native" && turns()["agent_codex"]?.sessionId == "external")
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
struct ApprovalInfo:Sendable { var id:UUID = UUID(); var pillId:String; var sessionId:String; var threadId:String?; var turnId:String?; var requestId:String?; var tool:String; var command:String; var inputKey:String }
@MainActor final class AppState { static let shared = AppState(); @Published var codexChatBusy = false; @Published var tasks:[AgentTask] = []; @Published var pendingApproval:ApprovalInfo?; @Published var waitingQuestions:[QueuedQuestion] = [] }
enum PillCatalog { static func isSession(_ id:String) -> Bool { true }; static func basePillId(_ id:String)->String { String(id.split(separator:"#",maxSplits:1)[0]) } }
@MainActor final class CloudProbe { nonisolated static let containerID = "iCloud.fr.louisraille.Coucou"; static let shared = CloudProbe(); static let isEnabled = false; var lastPushAt:Date?; static var zoneID:CKRecordZone.ID { .init(zoneName:"Coucou", ownerName:CKCurrentUserDefaultName) }; func log(_ message:String) {} }
@MainActor final class CodexChatService { static let shared = CodexChatService(); var isBusy = false; func owns(threadId:String)->Bool { true }; func sendManagedInstruction(threadId:String,text:String,expectedCwd:String) async throws {} }
@MainActor final class HookServer { static let shared = HookServer(); var answers:[UUID]=[]; func sendQuestionAnswers(_ answers:[String:Any], for id:UUID? = nil) { if let id { self.answers.append(id) } }; func sendApprovalDecision(_ decision:String, for id:UUID? = nil) {} }
@MainActor final class DemoEngine { static let shared = DemoEngine(); var isActive=false }

@main enum SnapshotCheck {
    @MainActor static func main() {
        UserDefaults.standard.register(defaults: [InstructionRunner.enabledKey: true])
        var task = AgentTask(id: "agent_codex", codexManaged: true, codexThreadId: "child", codexTurnId: "t1", sessionId: "root", sessionCwd: "/chosen", state: .finished, source: .workspace, name: "project", color: "#ffffff", stepIndex: 0, steps: [], finalLine: "done")
        let finished = SessionSnapshot.all(tasks: [task], approval: nil, questions: [])[task.id]!
        assert(!finished.instructionTargetIdentity.isEmpty)
        CodexChatService.shared.isBusy = true
        let cleanupPending = SessionSnapshot.all(tasks: [task], approval: nil, questions: [])[task.id]!
        assert(cleanupPending.instructionTargetIdentity == finished.instructionTargetIdentity && !cleanupPending.acceptsInstructions)
        task.state = .working
        let busy = SessionSnapshot.all(tasks: [task], approval: nil, questions: [])[task.id]!
        assert(busy.instructionTargetIdentity == finished.instructionTargetIdentity && !busy.acceptsInstructions)
        task.codexTurnId = "t2"
        let next = SessionSnapshot.all(tasks: [task], approval: nil, questions: [])[task.id]!
        assert(next.instructionTargetIdentity != busy.instructionTargetIdentity)
        task.state = .question
        let secret = AskQuestion(questions: [.init(question: "Sensitive prompt", header: "", options: [], multiSelect: false, id: "q", isOther: false, isSecret: true)], pillId: task.id, threadId: "child", turnId: "t2", requestId: "secret")
        let secretEntry = QueuedQuestion(id: UUID(), fd: -1, sessionId: "root", pillId: task.id, projectName: "secret", cwd: "/chosen", question: secret)
        let hidden = SessionSnapshot.all(tasks: [task], approval: nil, questions: [secretEntry])[task.id]!
        assert(hidden.question.isEmpty && hidden.questionPayload.isEmpty && hidden.questionFingerprint.isEmpty)
        let secondSecret = QueuedQuestion(id: UUID(), fd: -1, sessionId: "other", pillId: task.id, projectName: "secret", cwd: "/chosen", question: secret, slot: 2)
        assert(SessionSnapshot.all(tasks: [task], approval: nil, questions: [secondSecret])[task.id+"#q2"] == nil)
        let now = Date()
        func entry(_ id: UUID, session: String, slot: Int = 1, shown: String? = nil) -> QueuedQuestion {
            let ask = AskQuestion(questions: [.init(question:"Same question", header:"Q", options:[.init(label:"Yes",description:"")],multiSelect:false,id:"choice",isOther:false)], pillId:"agent_codex", sessionId:session, threadId:"child", turnId:"t2", requestId:id.uuidString)
            return QueuedQuestion(id:id,fd:-1,sessionId:session,pillId:"agent_codex",projectName:session,cwd:"/chosen",question:ask,slot:slot,received:now,shownPill:shown)
        }
        let firstID=UUID(), secondID=UUID()
        let first=entry(firstID,session:"root"), second=entry(secondID,session:"sibling",slot:2)
        let separate=SessionSnapshot.all(tasks:[task],approval:nil,questions:[first,second])
        assert(separate[task.id]?.questionFingerprint == QuestionPayload(ask:first.question).fingerprint)
        let questionOnly=separate[task.id+"#q2"]!
        assert(!questionOnly.takesInstructions && !questionOnly.acceptsInstructions && questionOnly.instructionTargetIdentity.isEmpty)
        CodexChatService.shared.isBusy = false
        var popped=task; popped.id="agent_codex#2"; popped.state = .finished
        let nativeTarget=InstructionRunner.targetIdentity(for:popped)
        assert(nativeTarget != nil)
        popped.codexManaged=false; assert(InstructionRunner.targetIdentity(for:popped) == nil)
        popped.codexManaged=true; popped.state = .question
        let poppedQuestion=entry(UUID(),session:"popped",shown:popped.id)
        let poppedRecord=SessionSnapshot.all(tasks:[task,popped],approval:nil,questions:[first,poppedQuestion])
        assert(poppedRecord[popped.id]?.questionFingerprint == QuestionPayload(ask:poppedQuestion.question).fingerprint)
        var claude=popped; claude.id="integration_claude#2"; claude.state = .finished; claude.codexManaged=false; claude.codexThreadId=nil; claude.codexTurnId=nil; claude.sessionId="claude-original"
        assert(InstructionRunner.targetIdentity(for:claude) == SessionInstructionIdentity.make(pillId:claude.id,sessionId:"claude-original",threadId:nil,cwd:"/chosen"))
        AppState.shared.waitingQuestions=[first,second,secretEntry]
        func reply(_ q:QueuedQuestion,record:String?=nil,at:Date?=nil,choice:String="Yes") {
            QuestionRelay.shared.apply(.init(id:CKRecord.ID(recordName:UUID().uuidString),fingerprint:QuestionPayload(ask:q.question).fingerprint,recordId:record ?? q.phoneRecordId,answeredAt:at ?? now,selections:QuestionPayload.encodeSelections([[choice]])))
        }
        reply(second,record:first.phoneRecordId); assert(HookServer.shared.answers.isEmpty)
        reply(second,at:now.addingTimeInterval(-6)); assert(HookServer.shared.answers.isEmpty)
        reply(second,choice:"Unknown"); assert(HookServer.shared.answers.isEmpty)
        reply(secretEntry); assert(HookServer.shared.answers.isEmpty)
        reply(second); assert(HookServer.shared.answers == [secondID])
        AppState.shared.waitingQuestions.removeAll { $0.id == secondID }
        reply(second); assert(HookServer.shared.answers == [secondID])
        reply(first); assert(HookServer.shared.answers == [secondID,firstID])
        let approval = ApprovalInfo(pillId: task.id, sessionId: "root", threadId: "child", turnId: "t2", requestId: "r",
            tool: "Bash", command: "pwd", inputKey: "{}")
        var repeated = approval
        repeated.id = UUID()
        assert(ApprovalRelay.fingerprint(repeated) != ApprovalRelay.fingerprint(approval))
        repeated = approval
        repeated.turnId = "t3"
        assert(ApprovalRelay.fingerprint(repeated) != ApprovalRelay.fingerprint(approval))
        print("PASS: actual SessionSnapshot/QuestionRelay queue siblings, popped rows, question-only instruction exclusion, secret/stale/choice guards and approval identities")
    }
}
SWIFT
python3 - "$TEST_DIR/QuestionRelayCheck.swift" <<'PYFIXTURE'
from pathlib import Path
import sys
source = Path('NotchBuddy/Sources/App/PhoneLink/QuestionRelay.swift').read_text()
source = source.replace('private struct Answer {', 'struct Answer {').replace('private func apply(_ answer: Answer)', 'func apply(_ answer: Answer)')
# The fixture calls only the reply guard; do not initialize a real CloudKit container.
source = source.replace('private let container = CKContainer(', 'private lazy var container = CKContainer(')
Path(sys.argv[1]).write_text(source)
PYFIXTURE
swiftc -swift-version 6 -D PHONE_LINK NotchBuddy/Sources/CoucouKit/DiffEngine.swift \
    NotchBuddy/Sources/CoucouKit/TurnSnapshot.swift NotchBuddy/Sources/CoucouKit/QuestionPayload.swift \
    NotchBuddy/Sources/App/QuestionQueue.swift \
    NotchBuddy/Sources/App/AskQuestion.swift NotchBuddy/Sources/App/PhoneLink/TurnRecorder.swift \
    NotchBuddy/Sources/App/PhoneLink/InstructionRunner.swift NotchBuddy/Sources/App/PhoneLink/SessionPublisher.swift \
    NotchBuddy/Sources/App/PhoneLink/ApprovalRelay.swift "$TEST_DIR/QuestionRelayCheck.swift" \
    "$TEST_DIR/SnapshotCheck.swift" -o "$TEST_DIR/snapshot-check"
"$TEST_DIR/snapshot-check"
