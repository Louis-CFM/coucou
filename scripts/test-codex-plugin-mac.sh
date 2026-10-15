#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d)
trap 'rm -rf "$task_tmp"' EXIT
# Compile the actual parser and socket question dispatch. UI/RPC and scheduling
# are fixtures; anonymous socketpairs never touch a user's hook, home or Codex.
python3 - "$task_tmp/Check.swift" <<'PY'
from pathlib import Path
import sys
s = Path('NotchBuddy/Sources/App/HookServer.swift').read_text()
types = Path('NotchBuddy/Sources/CoucouKit/IslandTypes.swift').read_text()
info = types[types.index('struct ApprovalInfo:'):types.index('// MARK: - Pill badge')]
props = s[s.index('    private struct NativeRequest {'):s.index('    #endif', s.index('    private struct NativeRequest {'))]
helpers = s[s.index('    // MARK: - Question fd helpers'):s.index('    /// Returns the tool_input serialized')]
owners = s[s.index('    @MainActor\n    private func upsertTask('):s.index('    @MainActor\n    private func upsertWorkspaceTask(')]
process = s[s.index('    @MainActor\n    private func processQuestionRequest('):s.index('    /// "VS Code", "Warp"')]
current = s[s.index('    @MainActor\n    private func isCurrentCodexRequest('):s.index('    @MainActor\n    private func replyNativeApproval(')]
resolve = s[s.index('    @MainActor\n    func resolveCodexRequests('):s.index('    #endif', s.index('    @MainActor\n    func resolveCodexRequests('))]
client = s[s.index('    private func handleClient('):s.index('    // MARK: - Event → AppState')]
limits = s[s.index('    private static let maxPayload'):s.index('    private var serverFD')]
permission_start = s.index('    @MainActor\n    private func processPermissionRequest(')
# Only the production early ownership/card guard belongs to this fixture; the
# ordinary permission queue is compiled by test-codex-session-queue.sh.
permission = s[permission_start:s.index('        let state = AppState.shared', permission_start)]
permission += '        fatalError("Ordinary permission queue is outside this fixture")\n    }\n'
# Keep the production callback bodies, substituting only the read-source/timer
# boundary so a stale EOF or 120-second timeout can be invoked deterministically.
assert process.count('DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)') == 1
assert process.count('DispatchQueue.main.asyncAfter(deadline: .now() + 120)') == 1
process = process.replace('DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)', 'ReadSource()')
process = process.replace('DispatchQueue.main.asyncAfter(deadline: .now() + 120)', 'captureTimeout')
Path(sys.argv[1]).write_text('''import Foundation
import Dispatch
import Darwin

'''+info+'''
extension Notification.Name { static let islandCollapse = Notification.Name("islandCollapse") }
enum View { case overview, empty, note, question, approval }
enum State { case idle, working, question, approval }
struct TaskInfo {
    var id: String
    var state = State.idle
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
@MainActor final class AppState {
    static let shared = AppState()
    var pendingQuestion: AskQuestion?
    var pendingApproval: ApprovalInfo?
    var isPinned = false
    var focusId: String? = "integration_claude"
    var view = View.overview
    var noteMessage = ""
    var tasks = [TaskInfo(id: "integration_claude"), TaskInfo(id: "agent_codex")]
    func updateTask(id: String, state: State) {
        if let index = tasks.firstIndex(where: { $0.id == id }) { tasks[index].state = state }
    }
}
@MainActor final class DemoEngine {
    static let shared = DemoEngine()
    var isActive = false
    func handleQuestionAnswered(answers: [String: Any]) {}
}
@MainActor final class RecapStore {
    static let shared = RecapStore()
    func recordQuestionAnswered(sessionId: String) {}
}
@MainActor final class SoundEngine {
    static let shared = SoundEngine()
    func play(_ name: String) {}
}
@MainActor final class CodexChatService {
    static let shared = CodexChatService()
    var turnId: String? = "turn"
    func owns(threadId: String) -> Bool { threadId == "native" }
}
@MainActor final class CodexConnection {
    static let shared = CodexConnection()
    var replies: [(Int, [String: Any])] = []
    var interrupts = 0
    func respond(id: Any, result: [String: Any]) throws { replies.append((id as! Int, result)) }
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        interrupts += 1; return [:]
    }
}
@MainActor enum CodexEventAdapter {
    static let shared = Self.self
    static func isManagedHookSession(_ id: String) -> Bool { id == "native-hook" }
}
enum ClaudeHost {
    struct Host { var bundleId: String }
    static var terminalCardsEnabled: Bool { false }
    static func terminal(termProgram: String, bundleId: String) -> Host? { nil }
}
final class ReadSource: @unchecked Sendable {
    var onRead: (@MainActor @Sendable () -> Void)?
    var onCancel: (@Sendable () -> Void)?
    private var canceled = false
    @MainActor func setEventHandler(handler: @escaping @MainActor @Sendable () -> Void) { onRead = handler }
    func setCancelHandler(handler: @escaping @Sendable () -> Void) { onCancel = handler }
    func resume() {}
    func cancel() {
        if !canceled { canceled = true; onCancel?() }
    }
    @MainActor func fire() { onRead?() }
}
final class HookServer: @unchecked Sendable {
    static let shared = HookServer()
    private init() {}
'''+limits+'''
    private let connectionLock = NSLock()
    private var connectionCount = 0
    private var approvals = ApprovalQueue()
    private var sessions = PillSessionRegistry()
    private var pendingQuestionFD: Int32 = -1
    private var questionFDSource: ReadSource?
    private var questionPillId = ""
    private var questionSessionId = ""
    private var focusBeforeQuestion: String?
    private var activeSessionId: String?
    @MainActor private var timeouts: [@MainActor @Sendable () -> Void] = []
    @MainActor var hasRealPendingApproval: Bool { !approvals.isEmpty }
    @MainActor var hasRealPendingQuestion: Bool { pendingQuestionFD >= 0 || codexQuestion != nil }
'''+props+'''
    func sendLine(fd: Int32, text: String) {
        let data = Array((text + "\\n").utf8)
        assert(write(fd, data, data.count) == data.count)
    }
    @MainActor func captureTimeout(_ work: @escaping @MainActor @Sendable () -> Void) { timeouts.append(work) }
    @MainActor func clearPillBadge(id: String) {}
    @MainActor func expandIfNeeded(to view: View) { AppState.shared.view = view }
    @MainActor func removeApproval(id: UUID) { codexApprovals.removeValue(forKey: id) }
    private static func nativeRequestKey(_ id: Any) -> String { "[\\(id)]" }
    func aliasProjectName(_ name: String) -> String { name }
    @MainActor func sessionDisplay(payload: [String: Any], session: String, projectName: String,
                                   cwd: String, hostApp: String?) -> PillSessionRegistry.Display {
        PillSessionRegistry.Display(session: session, projectName: projectName, cwd: cwd)
    }
    @MainActor func upsertWorkspaceTask(id: String) { applyDisplayOwner(pill: id) }
    @MainActor func upsertExternalAgent(id: String, name: String) {}
    @MainActor func processStatusLine(payload: [String: Any]) { fatalError("Unexpected statusline") }
    @MainActor func processEvent(name: String, payload: [String: Any]) { fatalError("Unexpected event") }
'''+client+permission+owners+helpers+current+resolve+process+'''
    static func sockets(reusing fd: Int32? = nil) -> [Int32] {
        var pair: [Int32] = [0, 0]
        assert(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        if let fd, pair[0] != fd {
            assert(pair[1] != fd && dup2(pair[0], fd) == fd)
            close(pair[0]); pair[0] = fd
        }
        assert(fcntl(pair[1], F_SETFL, O_NONBLOCK) == 0)
        return pair
    }
    static func response(_ peer: Int32) async -> [String: Any] {
        var all = Data()
        for _ in 0..<200 {
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = read(peer, &bytes, bytes.count)
            if count > 0 { all.append(contentsOf: bytes.prefix(count)) }
            if all.last == 10 {
                close(peer)
                return try! JSONSerialization.jsonObject(with: all) as! [String: Any]
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        fatalError("No socket response within one second")
    }
    static func closed(_ fd: Int32) async {
        for _ in 0..<200 {
            if fcntl(fd, F_GETFD) < 0 { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        fatalError("Question fd was not closed")
    }
    static func noReply(_ peer: Int32) {
        var byte: UInt8 = 0
        assert(read(peer, &byte, 1) < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
    }
    static func packet(_ payload: [String: Any], suffix: String = "") async -> [Int32] {
        let pair = sockets()
        let bytes = Array((String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)! + "\\n" + suffix).utf8)
        Task.detached { shared.handleClient(fd: pair[0]) }
        var offset = 0, waits = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { buffer in
                write(pair[1], buffer.baseAddress!.advanced(by: offset), min(997, bytes.count - offset))
            }
            if count > 0 { offset += count; continue }
            assert(errno == EAGAIN || errno == EWOULDBLOCK)
            waits += 1; assert(waits < 200)
            try? await Task.sleep(for: .milliseconds(5))
        }
        return pair
    }
    @MainActor static func displayed(session: String) async {
        for _ in 0..<200 {
            if AppState.shared.pendingQuestion?.sessionId == session { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        fatalError("Valid framed plugin packet did not reach the question card")
    }
    @MainActor static func check() async {
        let server = shared, state = AppState.shared
        let input: [String: Any] = ["questions": [["id": "choice", "question": "Choose?",
            "header": "abcdefghijklmnop", "isOther": true, "options": [["label": "One", "description": "First"], ["label": "Two"]]],
            ["id": "free", "prompt": "Write a reply"], ["id": "secret", "question": "Fixture secret", "isSecret": true]]]
        let plugin = AskQuestion.parseCodexPlugin(input)!
        assert(plugin.isCodexPlugin && plugin.pillId == "agent_codex" && plugin.requestId == nil
            && plugin.sessionId == nil && plugin.threadId == nil && plugin.turnId == nil)
        assert(plugin.questions[0].header == "abcdefghijkl" && plugin.questions[0].isOther
            && plugin.questions[0].hasDescriptions && !plugin.questions[0].multiSelect)
        assert(plugin.questions[1].options.isEmpty && !plugin.questions[1].isOther
            && plugin.questions[2].isSecret && !plugin.questions[2].multiSelect)
        let rows = input["questions"] as! [[String: Any]]
        assert(AskQuestion.parseCodexPlugin(["questions": [rows[0], rows[1], rows[2],
            ["id": "four", "question": "Fourth?", "options": NSNull()]]])?.questions.count == 4)
        assert(AskQuestion.parseCodexPlugin([:]) == nil)
        assert(AskQuestion.parseCodexPlugin(["questions": []]) == nil)
        assert(AskQuestion.parseCodexPlugin(["questions": "bad"]) == nil)
        assert(AskQuestion.parseCodexPlugin(["questions": Array(repeating: rows[0], count: 5)]) == nil)
        assert(AskQuestion.parseCodexPlugin(["questions": [rows[0], rows[0]]]) == nil)
        for bad: [String: Any] in [["id": "", "question": "Q"], ["id": 1, "question": "Q"],
            ["id": "x", "question": ""], ["id": "x", "question": "Q", "options": "bad"],
            ["id": "x", "question": "Q", "options": ["bad"]],
            ["id": "x", "question": "Q", "options": [["label": ""]]]] {
            assert(AskQuestion.parseCodexPlugin(["questions": [bad]]) == nil)
        }
        for (key, limit) in [("id", 512), ("question", 32768)] {
            var item: [String: Any] = ["id": "x", "question": "Q"]
            item[key] = String(repeating: "a", count: limit)
            assert(AskQuestion.parseCodexPlugin(["questions": [item]]) != nil)
            item[key] = String(repeating: "a", count: limit + 1)
            assert(AskQuestion.parseCodexPlugin(["questions": [item]]) == nil)
        }
        for (key, limit) in [("label", 4096), ("description", 8192)] {
            var option: [String: Any] = ["label": "One"]
            option[key] = String(repeating: "a", count: limit)
            assert(AskQuestion.parseCodexPlugin(["questions": [["id": "x", "question": "Q", "options": [option]]]]) != nil)
            option[key] = String(repeating: "a", count: limit + 1)
            assert(AskQuestion.parseCodexPlugin(["questions": [["id": "x", "question": "Q", "options": [option]]]]) == nil)
        }
        let nine = (1...9).map { ["label": "Choice \\($0)"] }
        assert(AskQuestion.parseCodexPlugin(["questions": [["id": "x", "question": "Q", "options": nine]]]) != nil)
        assert(AskQuestion.parseCodexPlugin(["questions": [["id": "x", "question": "Q", "options": nine + [["label": "Ten"]]]]]) == nil)

        let payload: [String: Any] = ["coucou_agent": "codex", "session_id": "plugin", "cwd": "/fixture/project",
            "bundle_id": "com.openai.codex"]
        let first = sockets()
        server.processQuestionRequest(fd: first[0], parsed: plugin, payload: payload)
        let firstID = state.pendingQuestion!.requestId!
        let firstSource = server.questionFDSource!, firstTimeout = server.timeouts.last!
        assert(state.pendingQuestion!.isCodexPlugin && state.pendingQuestion!.threadId == nil
            && state.pendingQuestion!.projectName == "project"
            && server.pendingQuestionFD == first[0] && state.view == .question)
        let busy = sockets()
        server.processQuestionRequest(fd: busy[0], parsed: plugin, payload: payload)
        let busyReply = await response(busy[1]); await closed(busy[0])
        assert(busyReply["permissionDecision"] as? String == "ask")
        assert(state.pendingQuestion?.requestId == firstID && server.pendingQuestionFD == first[0])
        let answers = AskQuestion.buildAnswers(questions: plugin.questions, selections: [["Two"], ["Free text"], ["fixture-only"]])
        server.sendQuestionAnswers(answers, for: "stale")
        server.sendQuestionAnswers(answers)
        noReply(first[1])
        assert(server.pendingQuestionFD == first[0])
        server.sendQuestionAnswers(answers, for: firstID)
        let firstReply = await response(first[1]); await closed(first[0])
        assert(firstReply["permissionDecision"] as? String == "answer")
        let values = firstReply["answers"] as! [String: [String: [String]]]
        assert(values["choice"]?["answers"] == ["Two"] && values["free"]?["answers"] == ["Free text"]
            && values["secret"]?["answers"] == ["fixture-only"] && state.pendingQuestion == nil)
        assert(server.sessions.liveCount(pill: "agent_codex") == 0 && state.tasks[1].state == .idle)

        // Force OS fd reuse: old timer/EOF/button callbacks must not touch the next card.
        let second = sockets(reusing: first[0])
        server.processQuestionRequest(fd: second[0], parsed: plugin, payload: payload)
        let secondID = state.pendingQuestion!.requestId!
        firstSource.fire(); firstTimeout()
        server.sendQuestionAnswers(answers, for: firstID)
        server.sendQuestionAsk(for: firstID); server.releaseQuestionFD(for: firstID)
        noReply(second[1])
        assert(server.pendingQuestionFD == second[0] && state.pendingQuestion?.requestId == secondID)
        server.timeouts.last!()
        let timeoutReply = await response(second[1]); await closed(second[0])
        assert(timeoutReply["permissionDecision"] as? String == "ask" && state.pendingQuestion == nil)
        assert(server.sessions.liveCount(pill: "agent_codex") == 0 && state.tasks[1].state == .idle)
        let eof = sockets()
        server.processQuestionRequest(fd: eof[0], parsed: plugin, payload: payload)
        server.questionFDSource!.fire(); await closed(eof[0])
        var byte: UInt8 = 0
        assert(read(eof[1], &byte, 1) == 0 && state.pendingQuestion == nil); close(eof[1])
        assert(server.sessions.liveCount(pill: "agent_codex") == 0 && state.tasks[1].state == .idle)

        let canceled = sockets()
        server.processQuestionRequest(fd: canceled[0], parsed: plugin, payload: payload)
        server.sendQuestionAsk(for: state.pendingQuestion!.requestId!)
        let canceledReply = await response(canceled[1]); await closed(canceled[0])
        assert(canceledReply["permissionDecision"] as? String == "ask"
            && server.sessions.liveCount(pill: "agent_codex") == 0 && state.tasks[1].state == .idle)
        let releasedAlone = sockets()
        server.processQuestionRequest(fd: releasedAlone[0], parsed: plugin, payload: payload)
        server.releaseQuestionFD(for: state.pendingQuestion!.requestId!)
        let releasedAloneReply = await response(releasedAlone[1]); await closed(releasedAlone[0])
        assert(releasedAloneReply["permissionDecision"] as? String == "ask" && state.pendingQuestion == nil
            && server.sessions.liveCount(pill: "agent_codex") == 0 && state.tasks[1].state == .idle)

        server.sessions.note(pill: "agent_codex", display: PillSessionRegistry.Display(session: "idle-sibling",
            projectName: "Idle sibling", cwd: "/idle", bundleId: "com.openai.codex"), working: false)
        let idleSibling = sockets()
        server.processQuestionRequest(fd: idleSibling[0], parsed: plugin, payload: payload)
        server.sendQuestionAnswers(answers, for: state.pendingQuestion!.requestId!)
        _ = await response(idleSibling[1]); await closed(idleSibling[0])
        assert(server.sessions.liveCount(pill: "agent_codex") == 1
            && server.sessions.workingCount(pill: "agent_codex") == 0
            && state.tasks[1].state == .idle && state.tasks[1].name == "Idle sibling"
            && state.tasks[1].sessionId == "idle-sibling")
        _ = server.sessions.endSession(pill: "agent_codex", session: "idle-sibling")

        let legacy = AskQuestion.parse(toolInput: ["questions": [["question": "Legacy?", "options": [["label": "Yes"], ["label": "No"]]]]])!
        let replacedPlugin = sockets()
        server.processQuestionRequest(fd: replacedPlugin[0], parsed: plugin, payload: payload)
        let replacedID = state.pendingQuestion!.requestId!
        let replacedSource = server.questionFDSource!, replacedTimeout = server.timeouts.last!
        let replacement = sockets()
        server.processQuestionRequest(fd: replacement[0], parsed: legacy,
            payload: ["session_id": "claude", "bundle_id": "com.microsoft.VSCode"])
        let replacementID = state.pendingQuestion!.requestId!
        let replacedReply = await response(replacedPlugin[1]); await closed(replacedPlugin[0])
        assert(replacedReply["permissionDecision"] as? String == "ask"
            && server.sessions.liveCount(pill: "agent_codex") == 0 && state.tasks[1].state == .idle)
        replacedSource.fire(); replacedTimeout()
        server.sendQuestionAnswers(answers, for: replacedID)
        server.sendQuestionAsk(for: replacedID); server.releaseQuestionFD(for: replacedID)
        noReply(replacement[1])
        assert(state.pendingQuestion?.requestId == replacementID && server.pendingQuestionFD == replacement[0]
            && state.isPinned && state.view == .question)
        server.sendQuestionAsk(for: replacementID)
        _ = await response(replacement[1]); await closed(replacement[0])
        let claude = sockets()
        server.processQuestionRequest(fd: claude[0], parsed: legacy,
            payload: ["session_id": "claude", "bundle_id": "com.microsoft.VSCode"])
        let claudeID = state.pendingQuestion!.requestId!
        assert(!state.pendingQuestion!.isCodexPlugin && state.pendingQuestion!.pillId == "integration_claude")
        let pluginWhileClaude = sockets()
        server.processQuestionRequest(fd: pluginWhileClaude[0], parsed: plugin, payload: payload)
        let claudeBusy = await response(pluginWhileClaude[1]); await closed(pluginWhileClaude[0])
        assert(claudeBusy["permissionDecision"] as? String == "ask" && state.pendingQuestion?.requestId == claudeID)
        server.sendQuestionAnswers(AskQuestion.buildAnswers(questions: legacy.questions, selections: [["Yes"]]), for: claudeID)
        let claudeReply = await response(claude[1]); await closed(claude[0])
        assert((claudeReply["answers"] as? [String: String])?["Legacy?"] == "Yes")
        assert(server.sessions.liveCount(pill: "integration_claude") == 1
            && server.sessions.workingCount(pill: "integration_claude") == 1 && state.tasks[0].state == .working)

        let queued = QueuedApproval(id: UUID(), fd: -1, sessionId: "approval", pillId: "integration_claude",
            projectName: "Fixture", cwd: "/fixture", tool: "Bash", command: "pwd", inputKey: "")
        assert(server.approvals.enqueue(queued) == .accepted)
        state.view = .approval
        let approvalBusy = sockets()
        server.processQuestionRequest(fd: approvalBusy[0], parsed: plugin, payload: payload)
        let approvalReply = await response(approvalBusy[1]); await closed(approvalBusy[0])
        assert(approvalReply["permissionDecision"] as? String == "ask" && state.pendingQuestion == nil
            && server.approvals.head?.id == queued.id && state.view == .approval)
        _ = server.approvals.remove(id: queued.id)

        let nativeParams: [String: Any] = ["threadId": "native", "turnId": "turn", "questions": [rows[0]]]
        let native = AskQuestion.parseCodex(nativeParams, requestId: "[7]")!
        assert(!native.isCodexPlugin && native.threadId == "native" && native.turnId == "turn")
        server.sessions.note(pill: "agent_codex", display: PillSessionRegistry.Display(session: "native",
            projectName: "Fixture", cwd: "/fixture", codexThreadId: "native", codexTurnId: "turn", codexManaged: true), working: true)
        server.codexQuestion = NativeRequest(id: 7, method: "item/tool/requestUserInput", params: nativeParams, key: "[7]")
        state.pendingQuestion = native
        let nativeBusy = sockets()
        server.processQuestionRequest(fd: nativeBusy[0], parsed: plugin, payload: payload)
        let nativeReply = await response(nativeBusy[1]); await closed(nativeBusy[0])
        assert(nativeReply["permissionDecision"] as? String == "ask" && state.pendingQuestion?.requestId == "[7]")
        server.sendQuestionAnswers(answers, for: firstID)
        assert(CodexConnection.shared.replies.isEmpty)
        server.sendQuestionAnswers(answers, for: "[7]")
        assert(CodexConnection.shared.replies.count == 1 && CodexConnection.shared.replies[0].0 == 7)
        server.codexQuestion = NativeRequest(id: 8, method: "item/tool/requestUserInput", params: nativeParams, key: "[8]")
        state.pendingQuestion = AskQuestion.parseCodex(nativeParams, requestId: "[8]")
        CodexChatService.shared.turnId = "next-turn"
        server.sendQuestionAnswers(answers, for: "[8]")
        assert(CodexConnection.shared.replies.count == 1 && server.codexQuestion == nil && state.pendingQuestion == nil)

        let socketNative = sockets()
        server.processQuestionRequest(fd: socketNative[0], parsed: native, payload: payload)
        let socketNativeID = state.pendingQuestion!.requestId!
        server.sendQuestionAnswers(AskQuestion.buildAnswers(questions: native.questions, selections: [["One"]]), for: socketNativeID)
        let socketNativeReply = await response(socketNative[1]); await closed(socketNative[0])
        assert(((socketNativeReply["answers"] as? [String: [String: [String]]])?["choice"])?["answers"] == ["One"]
            && CodexConnection.shared.replies.count == 1)
        let released = sockets()
        server.processQuestionRequest(fd: released[0], parsed: plugin, payload: payload)
        state.pendingApproval = ApprovalInfo(sessionId: "other", tool: "Bash", command: "pwd", inputKey: "", pillId: "integration_claude")
        server.releaseQuestionFD(for: state.pendingQuestion!.requestId!)
        let releaseReply = await response(released[1]); await closed(released[0])
        assert(releaseReply["permissionDecision"] as? String == "ask" && CodexConnection.shared.replies.count == 1
            && state.isPinned && state.pendingApproval?.sessionId == "other")
        state.pendingApproval = nil; state.isPinned = false
        assert(server.sessions.liveCount(pill: "agent_codex") == 1
            && server.sessions.workingCount(pill: "agent_codex") == 1
            && server.sessions.display(pill: "agent_codex", session: "plugin") == nil
            && state.tasks[1].state == .working && state.tasks[1].sessionId == "native"
            && state.tasks[1].codexManaged && state.tasks[1].codexThreadId == "native")
        // A late EOF must finish its plugin session without dismissing a newer approval card.
        let crossing = sockets()
        server.processQuestionRequest(fd: crossing[0], parsed: plugin, payload: payload)
        let newerApproval = ApprovalInfo(sessionId: "new-approval", tool: "Bash", command: "pwd", inputKey: "", pillId: "agent_codex")
        state.pendingApproval = newerApproval
        state.view = .approval
        state.updateTask(id: "agent_codex", state: .approval)
        server.questionFDSource!.fire(); await closed(crossing[0])
        assert(read(crossing[1], &byte, 1) == 0); close(crossing[1])
        assert(state.pendingQuestion == nil && state.pendingApproval?.id == newerApproval.id
            && state.view == .approval && state.isPinned && state.tasks[1].state == .approval
            && server.focusBeforeQuestion == nil
            && server.sessions.display(pill: "agent_codex", session: "plugin") == nil)
        state.pendingApproval = nil; state.isPinned = false
        state.updateTask(id: "agent_codex", state: .working)
        let mirror = sockets()
        server.processQuestionRequest(fd: mirror[0], parsed: plugin,
            payload: ["coucou_agent": "codex", "session_id": "native-hook"])
        let mirrorReply = await response(mirror[1]); await closed(mirror[0])
        assert(mirrorReply["permissionDecision"] as? String == "ask" && state.pendingQuestion == nil)

        let validSession = UUID().uuidString
        let framed: [String: Any] = ["coucou_kind": "codex_mcp_question", "coucou_agent": "codex",
            "session_id": validSession, "request_id": UUID().uuidString,
            "cwd": CommandLine.arguments[1], "tool_input": input, "padding": String(repeating: "x", count: 6000)]
        // Multiple recv chunks and a second line must still display exactly the first request.
        let framedSocket = await packet(framed, suffix: "{\\"coucou_kind\\":\\"ignored-second-line\\"}\\n")
        await displayed(session: validSession)
        assert(state.pendingQuestion!.isCodexPlugin && state.pendingQuestion!.threadId == nil
            && state.pendingQuestion!.turnId == nil && server.pendingQuestionFD == framedSocket[0])
        let framedID = state.pendingQuestion!.requestId!
        let permissionSocket = await packet(["hook_event_name": "PermissionRequest", "session_id": "other",
            "tool_name": "Bash", "bundle_id": "com.microsoft.VSCode"])
        let permissionReply = await response(permissionSocket[1]); await closed(permissionSocket[0])
        assert(permissionReply["permissionDecision"] as? String == "ask"
            && state.pendingQuestion?.requestId == framedID && state.isPinned && state.view == .question)
        server.sendQuestionAnswers(answers, for: framedID)
        let framedReply = await response(framedSocket[1]); await closed(framedSocket[0])
        assert(((framedReply["answers"] as? [String: [String: [String]]])?["free"])?["answers"] == ["Free text"])
        assert(server.sessions.display(pill: "agent_codex", session: validSession) == nil)
        var atLimit = framed
        atLimit["session_id"] = UUID().uuidString
        let envelopeBytes = try! JSONSerialization.data(withJSONObject: framed).count - 6000
        atLimit["padding"] = String(repeating: "x", count: 131072 - envelopeBytes)
        assert(try! JSONSerialization.data(withJSONObject: atLimit).count == 131072)
        let boundarySocket = await packet(atLimit)
        await displayed(session: atLimit["session_id"] as! String)
        server.sendQuestionAsk(for: state.pendingQuestion!.requestId!)
        let boundaryReply = await response(boundarySocket[1]); await closed(boundarySocket[0])
        assert(boundaryReply["permissionDecision"] as? String == "ask" && state.pendingQuestion == nil)
        let invalidFields: [(String, Any)] = [("session_id", "bad-uuid"), ("request_id", "bad-uuid"),
            ("coucou_agent", "claude"), ("cwd", "relative"), ("cwd", "/missing-coucou-fixture-directory"),
            ("cwd", CommandLine.arguments[1] + "/Check.swift"), ("cwd", "/tmp\\0invalid"),
            ("coucou_managed", false), ("thread_id", "native"), ("turn_id", "turn"), ("rollout_path", "/fixture"),
            ("thread_id", NSNull()), ("padding", String(repeating: "x", count: 131073)),
            ("tool_input", ["questions": []])]
        for (key, value) in invalidFields {
            var malformed = framed
            malformed[key] = value
            let rejected = await packet(malformed)
            let rejection = await response(rejected[1]); await closed(rejected[0])
            assert(rejection["permissionDecision"] as? String == "ask" && state.pendingQuestion == nil
                && server.sessions.display(pill: "agent_codex", session: validSession) == nil)
        }
        print("PASS actual Codex plugin parser/client/socket dispatch: bounds, UUID/cwd/size/native spoof rejection, fragmented first-line routing, exact fd/ID, permission/busy preservation, stale callbacks, all finish paths, legacy replacement, sibling handoff, native ownership")
    }
}
@main enum Check {
    @MainActor static func main() async { await HookServer.check() }
}
''')
PY
swiftc -parse-as-library -swift-version 6 NotchBuddy/Sources/App/AskQuestion.swift \
    NotchBuddy/Sources/App/ApprovalQueue.swift NotchBuddy/Sources/App/PillSessionRegistry.swift \
    "$task_tmp/Check.swift" -o "$task_tmp/check"
"$task_tmp/check" "$task_tmp"
