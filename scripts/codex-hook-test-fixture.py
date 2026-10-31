"""Build the actual HookServer queue/board methods with isolated UI/RPC/socket scheduling."""
from pathlib import Path


def fixture() -> str:
    source = Path('NotchBuddy/Sources/App/HookServer.swift').read_text()
    types = Path('NotchBuddy/Sources/CoucouKit/IslandTypes.swift').read_text()
    def section(start, end):
        return source[source.index(start):source.index(end, source.index(start))]
    approval = section('    // MARK: - Approval queue helpers', '    // MARK: - Sessions on the board')
    board = section('    // MARK: - Sessions on the board', '    // MARK: - Question queue helpers')
    questions = section('    // MARK: - Question queue helpers', '    /// Returns the tool_input serialized')
    native = section('    @MainActor\n    func receiveCodexRequest(', '    #endif\n\n    // MARK: - Question request')
    process = section('    @MainActor\n    private func processQuestionRequest(', '    /// "VS Code", "Warp"')
    process = process.replace('DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)', 'ReadSource()')
    process = process.replace('DispatchQueue.main.asyncAfter(deadline: .now() + 120)', 'captureTimeout')
    names = section('    private func sessionName(', '    private func aliasProjectName(')
    methods = section('    /// Called by ApprovalView buttons', '    #if !APPSTORE\n    @MainActor\n    func receiveCodexEvent(')
    client = section('    private func handleClient(', '    // MARK: - Event → AppState')
    display = section('    @MainActor\n    private func sessionDisplay(', '    /// Updates or transiently creates a workspace pill')
    info = types[types.index('struct ApprovalInfo:'):types.index('// MARK: - Pill badge')]
    return r'''import Foundation
import Dispatch
import CryptoKit
import Darwin

'''+info+r'''
extension Notification.Name { static let islandCollapse = Notification.Name("islandCollapse") }
enum View { case approval, question, overview, empty, note }
enum BotState: String, CaseIterable { case idle, working, thinking, searching, approval, question, error, finished, ratelimit, sleeping, dizzy }
struct SessionLine: Equatable { var id: String; var title: String; var state: BotState; var lastStep: String; var isShown: Bool }
struct AgentTask: Equatable {
    var id: String
    var name = ""
    var color = "#000000"
    var state = BotState.idle
    var steps: [String] = []
    var source = "fixture"
    var isIntegration = true
    var stepIndex = 0
    var finalLine: String?
    var sessionLines: [SessionLine] = []
    var sessionCwd: String?
    var sessionId: String?
    var sessionBundleId: String?
    var sessionTerminalId: String?
    var codexThreadId: String?
    var codexTurnId: String?
    var codexRolloutPath: String?
    var codexManaged = false
    var hostApp: String?
    var pill: String { PillCatalog.basePillId(id) }
}
enum PillCatalog { static func basePillId(_ id: String) -> String { String(id.split(separator: "#", maxSplits: 1).first ?? "") } }
struct DiffStep { var filename: String; var added: Int; var removed: Int }
extension String { func parseDiffStep() -> DiffStep? { nil } }
struct Animation { static func spring(response: Double, dampingFraction: Double) -> Animation { Animation() } }
func withAnimation(_ animation: Animation, _ body: () -> Void) { body() }
@MainActor var logMessages: [String] = []
@MainActor func nbLog(_ message: String) { logMessages.append(message) }
@MainActor final class AppState {
    static let shared = AppState()
    var pendingApproval: ApprovalInfo?
    var pendingQuestion: AskQuestion?
    var waitingQuestions: [QueuedQuestion] = []
    var isPinned = false
    var focusId: String? = "integration_claude"
    var view = View.overview
    var noteMessage = ""
    var tasks = [AgentTask(id: "integration_claude"), AgentTask(id: "agent_codex")]
    func updateTask(id: String, state: BotState) { if let i = tasks.firstIndex(where: { $0.id == id }) { tasks[i].state = state } }
    func removeTask(id: String) { tasks.removeAll { $0.id == id } }
    func moveCodexSessionDiffs(to: String, threadId: String, turnId: String) {}
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
@MainActor final class SoundEngine { static let shared = SoundEngine(); func play(_ name: String) {} }
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
        else { replies.append((id as! Int, result["decision"] as? String ?? "permissions")) }
    }
    func reject(id: Any, message: String) throws { rejected.append(id as! Int) }
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { interrupts += 1; return [:] }
}
@MainActor enum CodexEventAdapter {
    static let shared = Self.self
    static func isManagedHookSession(_ id: String) -> Bool { id == "native-hook" }
    static func refreshDisplay(threadId: String, turnId: String) {}
}
enum SessionTarget { static func bundleId(payload: [String: Any]) -> String? { payload["bundle_id"] as? String } }
enum ClaudeHost {
    struct Host { var bundleId: String }
    @MainActor static var activated: [String?] = []
    @MainActor static func activate(_ bundleId: String?) { activated.append(bundleId) }
    static func name(for host: String?) -> String { "VS Code" }
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
    func cancel() { if !canceled { canceled = true; onCancel?() } }
    @MainActor func fire() { onRead?() }
}
final class HookServer: @unchecked Sendable {
    static let shared = HookServer()
    private init() {}
    private static let maxPayload = 1_048_576
    private static let receiveTimeoutSeconds: Int = 5
    private let connectionLock = NSLock()
    private var connectionCount = 0
    private var approvals = ApprovalQueue()
    private var approvalSources: [UUID: ReadSource] = [:]
    private var questions = QuestionQueue()
    private var questionSources: [UUID: ReadSource] = [:]
    private var shownQuestion: UUID?
    private var sessions = PillSessionRegistry()
    private var board = SessionBoard()
    private var focusBeforeApproval: String?
    private var focusBeforeQuestion: String?
    private var activeSessionId: String?
    @MainActor var hasRealPendingApproval: Bool { !approvals.isEmpty }
    @MainActor var hasRealPendingQuestion: Bool { !questions.isEmpty }
    private struct NativeRequest { let id: Any; let method: String; let params: [String: Any]; let key: String }
    @MainActor private var codexApprovals: [UUID: NativeRequest] = [:]
    @MainActor private var codexQuestions: [UUID: NativeRequest] = [:]
    @MainActor private var timeouts: [@MainActor @Sendable () -> Void] = []
    @MainActor func captureTimeout(_ work: @escaping @MainActor @Sendable () -> Void) { timeouts.append(work) }
    func sendLine(fd: Int32, text: String) {
        let data = Array((text + "\n").utf8)
        assert(Darwin.write(fd, data, data.count) == data.count)
    }
    @MainActor func clearPillBadge(id: String) {}
    @MainActor func expandIfNeeded(to view: View) { AppState.shared.view = view }
    func aliasProjectName(_ name: String) -> String { name }
    @MainActor func claudeHostName(pill: String) -> String { "VS Code" }
    @MainActor func projectCodexDiffs(threadId: String, turnId: String) {}
    @MainActor func upsertWorkspaceTask(id: String) {}
    @MainActor func upsertExternalAgent(id: String, name: String) {}
    @MainActor func processStatusLine(payload: [String: Any]) { fatalError("Unexpected statusline") }
    @MainActor func processEvent(name: String, payload: [String: Any]) { fatalError("Unexpected event") }
    @MainActor func processPermissionRequest(fd: Int32, payload: [String: Any]) {
        // Permission transport is covered by the approval queue fixture. This boundary
        // only verifies framing keeps the displayed question and routes a safe fallback.
        Task.detached { self.sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#); close(fd) }
    }
'''+approval+board+questions+methods+native+display+names+client+process


def socket_helpers() -> str:
    return r'''    static func sockets(reusing fd: Int32? = nil) -> [Int32] {
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
        let bytes = Array((String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)! + "\n" + suffix).utf8)
        Task.detached { shared.handleClient(fd: pair[0]) }
        var offset = 0, waits = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { buffer in
                Darwin.write(pair[1], buffer.baseAddress!.advanced(by: offset), min(997, bytes.count - offset))
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
'''
