#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d)
trap 'rm -rf "$task_tmp"' EXIT
# Compile the production queue dispatch and native ownership checks with in-memory
# transport/UI boundaries. No Codex process, hook socket or iCloud account is used.
python3 - "$task_tmp/Check.swift" <<'PY'
from pathlib import Path
import sys
s = Path('NotchBuddy/Sources/App/HookServer.swift').read_text()
types = Path('NotchBuddy/Sources/CoucouKit/IslandTypes.swift').read_text()
relay = Path('NotchBuddy/Sources/App/PhoneLink/ApprovalRelay.swift').read_text()
info = types[types.index('struct ApprovalInfo:'):types.index('// MARK: - Pill badge')]
fingerprint = relay[relay.index('    nonisolated static func fingerprint('):relay.index('\n    func start()')]
apply = relay[relay.index('    private func apply('):relay.index('\n    private func log(')]
apply = apply.replace('private func apply', 'static func apply')
queue = s[s.index('    /// Note shown when a request was answered outside Coucou.'):s.index('    // MARK: - Question fd helpers')]
methods = s[s.index('    /// Called by ApprovalView buttons'):s.index('    // MARK: - Question request')]
methods = methods.replace('    #if !APPSTORE\n', '').replace('    #endif\n', '')
questions = s[s.index('    /// Called by QuestionView.'):s.index('    /// Returns the tool_input serialized')]
questions = questions.replace('        #if !APPSTORE\n', '').replace('        #endif\n', '')
plugin_cleanup = s[s.index('    @MainActor\n    private func finishPluginQuestion('):s.index('    @MainActor\n    private func dismissQuestionCard(')]
socket_question = s[s.index('    @MainActor\n    private func processQuestionRequest('):s.index('    /// "VS Code", "Warp"')]
socket_question = socket_question.replace('        #if !APPSTORE\n', '').replace('        #else\n        let isCodexRequest = false\n', '').replace('        #endif\n', '')
owner = s[s.index('    @MainActor\n    private func applyDisplayOwner('):s.index('    @MainActor\n    private func upsertWorkspaceTask(')]
props = s[s.index('    private struct NativeRequest {'):s.index('    #endif', s.index('    private struct NativeRequest {'))]
props = props.replace('private ', '')
Path(sys.argv[1]).write_text('''import Foundation
import Dispatch
import CryptoKit
import Darwin

'''+info+'''
@MainActor enum ApprovalRelay {
'''+fingerprint+apply+'''
    static func log(_ message: String) {}
}
extension Notification.Name { static let islandCollapse = Notification.Name("islandCollapse") }
enum View { case approval, question, overview, empty, note }
enum State { case approval, question, working, idle }
struct TaskInfo {
    var id: String
    var name = ""
    var sessionCwd: String?
    var sessionId: String?
    var sessionBundleId: String?
    var sessionTerminalId: String?
    var codexThreadId: String?
    var codexTurnId: String?
    var codexRolloutPath: String?
    var codexManaged = false
    var hostApp: String?
}
struct Animation {
    static func spring(response: Double, dampingFraction: Double) -> Animation { Animation() }
}
func withAnimation(_ animation: Animation, _ body: () -> Void) { body() }
@MainActor var logMessages: [String] = []
@MainActor func nbLog(_ message: String) { logMessages.append(message) }
@MainActor final class AppState {
    static let shared = AppState()
    var pendingApproval: ApprovalInfo?
    var pendingQuestion: AskQuestion?
    var isPinned = false
    var focusId: String? = "integration_claude"
    var view = View.overview
    var noteMessage = ""
    var tasks = [TaskInfo(id: "integration_claude"), TaskInfo(id: "agent_codex")]
    func updateTask(id: String, state: State) {}
}
@MainActor final class DemoEngine {
    static let shared = DemoEngine()
    var isActive = false
    func handleApprovalDecision(_ decision: String) {}
    func handleQuestionAnswered(answers: [String: Any]) {}
}
@MainActor final class RecapStore {
    static let shared = RecapStore()
    var decisions: [String] = []
    func recordDecision(pillId: String, decision: String) { decisions.append(decision) }
    func recordQuestionAnswered(sessionId: String) {}
}
@MainActor final class SoundEngine {
    static let shared = SoundEngine()
    func play(_ name: String) {}
}
@MainActor final class CodexChatService {
    static let shared = CodexChatService()
    var threadId = "child"
    var turnId: String? = "turn"
    var canWrite = true
    var connected = true
    func owns(threadId: String) -> Bool { connected && self.threadId == threadId }
    func allowsProjectWrites(threadId: String) -> Bool { owns(threadId: threadId) && canWrite }
}
@MainActor final class CodexConnection {
    static let shared = CodexConnection()
    var replies: [(id: Int, decision: String)] = []
    var rejected: [Int] = []
    var answers: [(id: Int, value: [String: Any])] = []
    var interrupts = 0
    func respond(id: Any, result: [String: Any]) throws {
        if let value = result["answers"] as? [String: Any] { answers.append((id as! Int, value)) }
        replies.append((id as! Int, result["decision"] as? String ?? "permissions"))
    }
    func reject(id: Any, message: String) throws { rejected.append(id as! Int) }
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { interrupts += 1; return [:] }
}
@MainActor enum CodexEventAdapter {
    static let shared = Self.self
    static func isManagedHookSession(_ id: String) -> Bool { false }
}
enum ClaudeHost {
    struct Host { var bundleId: String }
    static var terminalCardsEnabled: Bool { false }
    static func terminal(termProgram: String, bundleId: String) -> Host? { nil }
}
final class HookServer: @unchecked Sendable {
    static let shared = HookServer()
    private init() {}
    private var approvals = ApprovalQueue()
    private var approvalSources: [UUID: any DispatchSourceRead] = [:]
    private var sessions = PillSessionRegistry()
    private var focusBeforeApproval: String?
    private var questionPillId = ""
    private var questionSessionId = ""
    private var pendingQuestionFD: Int32 = -1
    private var questionFDSource: (any DispatchSourceRead)?
    private var focusBeforeQuestion: String?
    private var activeSessionId: String?
    private let claudeHostName = "VS Code"
    @MainActor var hasRealPendingApproval: Bool { !approvals.isEmpty }
    @MainActor var hasRealPendingQuestion: Bool { pendingQuestionFD >= 0 || codexQuestion != nil }
'''+props+'''
    func sendLine(fd: Int32, text: String) { precondition(fd >= 0); let bytes = Array(text.utf8); _ = write(fd, bytes, bytes.count) }
    @MainActor func processEvent(name: String, payload: [String: Any]) {}
    @MainActor func clearPillBadge(id: String) {}
    @MainActor func expandIfNeeded(to view: View) { AppState.shared.view = view }
    @MainActor func dismissQuestionCard(note: String) { AppState.shared.pendingQuestion = nil; AppState.shared.isPinned = false }
    func aliasProjectName(_ name: String) -> String { name }
    @MainActor func sessionDisplay(payload: [String: Any], session: String, projectName: String, cwd: String, hostApp: String?) -> PillSessionRegistry.Display {
        PillSessionRegistry.Display(session: session, projectName: projectName, cwd: cwd)
    }
    @MainActor func upsertTask(pill: String, display: PillSessionRegistry.Display, working: Bool, externalAgent: String?) {}
'''+queue+methods+questions+plugin_cleanup+socket_question+owner+'''
    @MainActor static func check() async {
        let server = shared
        let state = AppState.shared
        let connection = CodexConnection.shared
        server.sessions.note(pill: "agent_codex", display: PillSessionRegistry.Display(session: "external-desktop",
            projectName: "Desktop project", cwd: "/desktop", bundleId: "com.openai.codex"), working: true)
        server.sessions.note(pill: "agent_codex", display: PillSessionRegistry.Display(session: "child",
            projectName: "Native project", cwd: "/native", hookSessionId: "root", codexThreadId: "child",
            codexTurnId: "turn", codexManaged: true), working: true)
        server.applyDisplayOwner(pill: "agent_codex")
        assert(state.tasks[1].name == "Desktop project" && !state.tasks[1].codexManaged)
        let socket = QueuedApproval(id: UUID(), fd: 42, sessionId: "external", pillId: "integration_claude",
            projectName: "CLI project", cwd: "/cli", tool: "Bash", command: "pwd", inputKey: "")
        assert(server.approvals.enqueue(socket) == .accepted)
        server.showApprovalHead()
        let socketFingerprint = ApprovalRelay.fingerprint(state.pendingApproval!)
        let params: [String: Any] = ["threadId": "child", "turnId": "turn", "command": "git status",
            "availableDecisions": ["accept", "decline", "acceptForSession"]]
        server.receiveCodexRequest(method: "item/commandExecution/requestApproval", params: params, id: 1)
        server.receiveCodexRequest(method: "item/commandExecution/requestApproval", params: params, id: 2)
        assert(server.approvals.count == 3 && server.codexApprovals.count == 2)
        assert(state.pendingApproval?.id == socket.id && state.pendingApproval?.queueCount == 3)
        assert(connection.replies.isEmpty)
        var pipes: [Int32] = [0, 0]
        assert(pipe(&pipes) == 0)
        let questionParams: [String: Any] = ["threadId": "child", "turnId": "turn",
            "questions": [["id": "choice", "question": "Proceed?", "options": [["label": "Yes"]]]]]
        let socketQuestion = AskQuestion.parseCodex(questionParams, requestId: "socket")!
        server.processQuestionRequest(fd: pipes[1], parsed: socketQuestion,
            payload: ["coucou_agent": "codex", "session_id": "external"])
        assert(state.pendingQuestion == nil && state.pendingApproval?.id == socket.id && state.view == .approval)
        var bytes = [UInt8](repeating: 0, count: 128)
        for _ in 0..<100 {
            if fcntl(pipes[1], F_GETFD) < 0 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        assert(fcntl(pipes[1], F_GETFD) < 0)
        let readCount = read(pipes[0], &bytes, bytes.count)
        close(pipes[0])
        assert(readCount > 0)
        let fallback = try! JSONSerialization.jsonObject(with: Data(bytes.prefix(readCount))) as! [String: String]
        assert(fallback["permissionDecision"] == "ask")
        server.removeApproval(id: socket.id)
        assert(logMessages.last?.hasSuffix(" s: dropped") == true)
        let first = state.pendingApproval!
        assert(first.requestId == "[1]" && first.threadId == "child" && first.turnId == "turn")
        assert(first.allowsSession && first.projectName == "Native project" && first.queueCount == 2)
        assert(ApprovalRelay.fingerprint(first) != socketFingerprint)
        var repeated = first
        repeated.id = UUID()
        assert(ApprovalRelay.fingerprint(repeated) != ApprovalRelay.fingerprint(first))
        server.sendApprovalDecision("allow")
        server.sendApprovalDecision("allow", for: socket.id)
        assert(!ApprovalRelay.apply("allow", fingerprint: socketFingerprint, pillId: "integration_claude"))
        assert(connection.replies.isEmpty && server.approvals.count == 2)
        assert(ApprovalRelay.apply("allow", fingerprint: ApprovalRelay.fingerprint(first), pillId: "agent_codex"))
        assert(connection.replies.count == 1 && connection.replies[0].id == 1
            && connection.replies[0].decision == "accept")
        assert(logMessages.last?.hasSuffix(" s: native request closed") == true)
        assert(state.pendingApproval?.requestId == "[2]" && state.pendingApproval?.queueCount == 1)
        assert(!ApprovalRelay.apply("allow", fingerprint: ApprovalRelay.fingerprint(first), pillId: "agent_codex"))
        server.sendApprovalDecision("allow", for: first.id)
        assert(connection.replies.count == 1)
        let second = state.pendingApproval!
        CodexChatService.shared.turnId = "new-turn"
        server.sendApprovalDecision("allow", for: second.id)
        assert(connection.replies.count == 2 && connection.replies[1].id == 2
            && connection.replies[1].decision == "decline")
        assert(logMessages.last?.hasSuffix(" s: native request closed") == true)
        assert(server.approvals.isEmpty && server.codexApprovals.isEmpty && state.pendingApproval == nil)
        server.receiveCodexRequest(method: "item/commandExecution/requestApproval", params: params, id: 3)
        assert(connection.rejected == [3])
        CodexChatService.shared.turnId = "turn"
        server.receiveCodexRequest(method: "item/tool/requestUserInput", params: questionParams, id: 20)
        let firstQuestionId = state.pendingQuestion!.requestId!
        server.resolveCodexRequests(requestId: 20)
        server.receiveCodexRequest(method: "item/tool/requestUserInput", params: questionParams, id: 21)
        let secondQuestionId = state.pendingQuestion!.requestId!
        let answer: [String: Any] = ["choice": ["answers": ["Yes"]]]
        server.sendQuestionAnswers(answer)
        server.sendQuestionAsk()
        server.releaseQuestionFD()
        server.sendQuestionAnswers(answer, for: firstQuestionId)
        server.sendQuestionAsk(for: firstQuestionId)
        server.releaseQuestionFD(for: firstQuestionId)
        assert(connection.answers.isEmpty && connection.interrupts == 0)
        assert(state.pendingQuestion?.requestId == secondQuestionId && server.codexQuestion?.key == secondQuestionId)
        server.sendQuestionAnswers(answer, for: secondQuestionId)
        assert(connection.answers.count == 1 && connection.answers[0].id == 21
            && (connection.answers[0].value["choice"] as? [String: [String]])?["answers"] == ["Yes"])
        assert(state.pendingQuestion == nil && server.codexQuestion == nil)
        server.receiveCodexRequest(method: "item/tool/requestUserInput", params: questionParams, id: 22)
        server.sendQuestionAsk(for: "[22]")
        assert(connection.answers.count == 2 && connection.answers[1].id == 22 && connection.answers[1].value.isEmpty)
        assert(state.pendingQuestion == nil && server.codexQuestion == nil)
        var sockets: [Int32] = [0, 0]
        assert(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        server.processQuestionRequest(fd: sockets[0], parsed: socketQuestion,
            payload: ["session_id": "claude", "bundle_id": "com.microsoft.VSCode"])
        let socketQuestionId = state.pendingQuestion!.requestId!
        server.sendQuestionAnswers(["Proceed?": "Yes"], for: firstQuestionId)
        assert(server.pendingQuestionFD == sockets[0] && state.pendingQuestion?.requestId == socketQuestionId)
        server.sendQuestionAnswers(["Proceed?": "Yes"], for: socketQuestionId)
        assert(server.pendingQuestionFD < 0 && state.pendingQuestion == nil)
        for _ in 0..<100 {
            if fcntl(sockets[0], F_GETFD) < 0 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        assert(fcntl(sockets[0], F_GETFD) < 0)
        let socketCount = read(sockets[1], &bytes, bytes.count)
        close(sockets[1])
        assert(socketCount > 0)
        let socketReply = try! JSONSerialization.jsonObject(with: Data(bytes.prefix(socketCount))) as! [String: Any]
        assert(socketReply["permissionDecision"] as? String == "answer")
        assert((socketReply["answers"] as? [String: String])?["Proceed?"] == "Yes")
        CodexChatService.shared.canWrite = false
        server.receiveCodexRequest(method: "item/fileChange/requestApproval", params: params, id: 4)
        assert(connection.replies.last?.id == 4 && connection.replies.last?.decision == "decline")
        assert(server.approvals.isEmpty)
        CodexChatService.shared.canWrite = true
        for id in 5...10 {
            server.receiveCodexRequest(method: "item/commandExecution/requestApproval", params: params, id: id)
        }
        assert(server.approvals.count == ApprovalQueue.maxPending && server.codexApprovals.count == ApprovalQueue.maxPending)
        assert(connection.replies.last?.id == 10 && connection.replies.last?.decision == "decline")
        server.resolveCodexRequests(requestId: 7)
        assert(server.approvals.count == 4 && server.codexApprovals.count == 4)
        server.resolveCodexRequests(threadId: "child")
        assert(server.approvals.isEmpty && server.codexApprovals.isEmpty && state.pendingApproval == nil)
        _ = server.sessions.endSession(pill: "agent_codex", session: "external-desktop")
        server.applyDisplayOwner(pill: "agent_codex")
        assert(state.tasks[1].sessionId == "root" && state.tasks[1].codexThreadId == "child"
            && state.tasks[1].codexTurnId == "turn" && state.tasks[1].codexManaged)
        server.sessions.note(pill: "agent_codex", display: PillSessionRegistry.Display(session: "external-new",
            projectName: "New external", cwd: "/external", bundleId: "com.openai.codex"), working: true)
        _ = server.sessions.endSession(pill: "agent_codex", session: "child")
        server.applyDisplayOwner(pill: "agent_codex")
        assert(state.tasks[1].sessionId == "external-new" && state.tasks[1].codexThreadId == nil
            && state.tasks[1].codexTurnId == nil && !state.tasks[1].codexManaged)
        assert(state.tasks[1].sessionBundleId == "com.openai.codex" && state.tasks[1].sessionCwd == "/external")
        var answerPipe: [Int32] = [0, 0]
        assert(pipe(&answerPipe) == 0)
        defer { close(answerPipe[0]); close(answerPipe[1]) }
        assert(fcntl(answerPipe[0], F_SETFL, O_NONBLOCK) == 0)
        let answered = QueuedApproval(id: UUID(), fd: answerPipe[1], sessionId: "external", pillId: "integration_claude",
            projectName: "CLI project", cwd: "/cli", tool: "Bash", command: "pwd", inputKey: "")
        assert(server.approvals.enqueue(answered) == .accepted)
        server.removeApproval(id: answered.id, answer: #"{"permissionDecision":"allow"}"#)
        assert(logMessages.last?.hasSuffix(" s: answered from Coucou") == true)
        var answerBytes = [UInt8](repeating: 0, count: 128)
        var answerCount = -1
        for _ in 0..<100 {
            answerCount = read(answerPipe[0], &answerBytes, answerBytes.count)
            if answerCount > 0 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        assert(answerCount > 0)
        assert(String(decoding: answerBytes.prefix(answerCount), as: UTF8.self) == #"{"permissionDecision":"allow"}"#)
        assert(server.approvals.isEmpty)
        print("PASS actual HookServer: display/identity handoff, mixed socket/native FIFO, bounded multiple native approvals, captured UUID/question ID, socket question fallback, stale turn/read-only denial, exact request cleanup, phone fingerprint")
    }
}
@main enum Check {
    @MainActor static func main() async { await HookServer.check() }
}
''')
PY
swiftc -parse-as-library -swift-version 6 NotchBuddy/Sources/App/ApprovalQueue.swift \
    NotchBuddy/Sources/App/PillSessionRegistry.swift NotchBuddy/Sources/App/AskQuestion.swift \
    "$task_tmp/Check.swift" -o "$task_tmp/check"
"$task_tmp/check"
