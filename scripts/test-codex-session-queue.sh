#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d)
trap 'rm -rf "$task_tmp"' EXIT
# Execute the production mixed question/approval queues with isolated transport/UI.
python3 - "$task_tmp/Check.swift" <<'PY'
from pathlib import Path
import runpy
import sys
shared = runpy.run_path('scripts/codex-hook-test-fixture.py')
relay = Path('NotchBuddy/Sources/App/PhoneLink/ApprovalRelay.swift').read_text()
fingerprint = relay[relay.index('    nonisolated static func fingerprint('):relay.index('\n    func start()')]
apply = relay[relay.index('    private func apply('):relay.index('\n    private func log(')].replace('private func apply', 'static func apply')
relay_type = '@MainActor enum ApprovalRelay {\n' + fingerprint + apply + '\n static func log(_ message: String) {}\n}\n'
Path(sys.argv[1]).write_text('import Foundation\nimport CryptoKit\n' + relay_type + shared['fixture']() + r'''
    @MainActor static func check() async {
        let server = shared
        let state = AppState.shared
        let connection = CodexConnection.shared
        server.sessions.note(pill: "agent_codex", display: PillSessionRegistry.Display(session: "external-desktop",
            projectName: "Desktop project", cwd: "/desktop", bundleId: "com.openai.codex"), working: true)
        server.record(pill: "agent_codex", session: "external-desktop", raw: "external-desktop", title: "Desktop project") { $0.state = .working }
        server.syncPill("agent_codex")
        server.sessions.note(pill: "agent_codex", display: PillSessionRegistry.Display(session: "child",
            projectName: "Native project", cwd: "/native", hookSessionId: "root", codexThreadId: "child",
            codexTurnId: "turn", codexManaged: true), working: true)
        server.record(pill: "agent_codex", session: "child", raw: "child", title: "Native project") { $0.state = .working }
        server.syncPill("agent_codex")
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
        assert(server.questions.count == 1 && server.questions.head?.fd == pipes[1])
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
        assert(ApprovalRelay.apply("allow", fingerprint: ApprovalRelay.fingerprint(first), pillId: first.pillId))
        assert(connection.replies.count == 1 && connection.replies[0].id == 1
            && connection.replies[0].decision == "accept")
        assert(logMessages.last?.hasSuffix(" s: native request closed") == true)
        assert(state.pendingApproval?.requestId == "[2]" && state.pendingApproval?.queueCount == 1)
        assert(!ApprovalRelay.apply("allow", fingerprint: ApprovalRelay.fingerprint(first), pillId: first.pillId))
        server.sendApprovalDecision("allow", for: first.id)
        assert(connection.replies.count == 1)
        let second = state.pendingApproval!
        CodexChatService.shared.turnId = "new-turn"
        server.sendApprovalDecision("allow", for: second.id)
        assert(connection.replies.count == 2 && connection.replies[1].id == 2
            && connection.replies[1].decision == "decline")
        assert(logMessages.last?.hasSuffix(" s: native request closed") == true)
        assert(server.approvals.isEmpty && server.codexApprovals.isEmpty && state.pendingApproval == nil)
        let deferredID = server.questions.head!.id
        assert(state.pendingQuestion?.requestId == deferredID.uuidString)
        server.sendQuestionAsk(for: deferredID)
        for _ in 0..<100 {
            if fcntl(pipes[1], F_GETFD) < 0 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        assert(fcntl(pipes[1], F_GETFD) < 0)
        let readCount = read(pipes[0], &bytes, bytes.count); close(pipes[0])
        let fallback = try! JSONSerialization.jsonObject(with: Data(bytes.prefix(readCount))) as! [String: String]
        assert(fallback["permissionDecision"] == "ask")

        server.receiveCodexRequest(method: "item/commandExecution/requestApproval", params: params, id: 3)
        assert(connection.rejected == [3])
        CodexChatService.shared.turnId = "turn"
        server.receiveCodexRequest(method: "item/tool/requestUserInput", params: questionParams, id: 20)
        let firstQuestionId = UUID(uuidString: state.pendingQuestion!.requestId!)!
        server.resolveCodexRequests(requestId: 20)
        server.receiveCodexRequest(method: "item/tool/requestUserInput", params: questionParams, id: 21)
        let secondQuestionId = UUID(uuidString: state.pendingQuestion!.requestId!)!
        let answer: [String: Any] = ["choice": ["answers": ["Yes"]]]
        server.sendQuestionAnswers(answer)
        server.sendQuestionAsk()
        server.releaseQuestionFD()
        server.sendQuestionAnswers(answer, for: firstQuestionId)
        server.sendQuestionAsk(for: firstQuestionId)
        server.releaseQuestionFD(for: firstQuestionId)
        assert(connection.answers.isEmpty && connection.interrupts == 0)
        assert(state.pendingQuestion?.requestId == secondQuestionId.uuidString && server.codexQuestions[secondQuestionId] != nil)
        server.sendQuestionAnswers(answer, for: secondQuestionId)
        assert(connection.answers.count == 1 && connection.answers[0].id == 21
            && (connection.answers[0].value["choice"] as? [String: [String]])?["answers"] == ["Yes"])
        assert(state.pendingQuestion == nil && server.codexQuestions.isEmpty)
        server.receiveCodexRequest(method: "item/tool/requestUserInput", params: questionParams, id: 22)
        server.sendQuestionAsk(for: UUID(uuidString: state.pendingQuestion!.requestId!)!)
        assert(connection.answers.count == 2 && connection.answers[1].id == 22 && connection.answers[1].value.isEmpty)
        assert(state.pendingQuestion == nil && server.codexQuestions.isEmpty)
        var sockets: [Int32] = [0, 0]
        assert(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        server.processQuestionRequest(fd: sockets[0], parsed: socketQuestion,
            payload: ["session_id": "claude", "bundle_id": "com.microsoft.VSCode"])
        let socketQuestionId = UUID(uuidString: state.pendingQuestion!.requestId!)!
        server.sendQuestionAnswers(["Proceed?": "Yes"], for: firstQuestionId)
        assert(server.questions.head?.fd == sockets[0] && state.pendingQuestion?.requestId == socketQuestionId.uuidString)
        server.sendQuestionAnswers(["Proceed?": "Yes"], for: socketQuestionId)
        assert(server.questions.isEmpty && state.pendingQuestion == nil)
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
        server.syncPill("agent_codex")
        assert(state.tasks[1].sessionId == "root" && state.tasks[1].codexThreadId == "child"
            && state.tasks[1].codexTurnId == "turn" && state.tasks[1].codexManaged)
        server.sessions.note(pill: "agent_codex", display: PillSessionRegistry.Display(session: "external-new",
            projectName: "New external", cwd: "/external", bundleId: "com.openai.codex"), working: true)
        server.record(pill: "agent_codex", session: "external-new", raw: "external-new", title: "New external") { $0.state = .working }
        _ = server.sessions.endSession(pill: "agent_codex", session: "child")
        server.syncPill("agent_codex")
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
        assert((try! JSONSerialization.jsonObject(with: Data(answerBytes.prefix(answerCount))) as! [String: String])["permissionDecision"] == "allow")
        assert(server.approvals.isEmpty)
        assert(HookServer.planTitle("\n  # Ship the change\nDetails") == "Ship the change")
        assert(HookServer.planTitle(nil) == "Plan")
        let planDecisions: [(String, String, String?)] = [
            ("plan_auto", "allow", "auto"), ("plan_default", "allow", "default"),
            ("plan_change", "change_plan", nil),
        ]
        for (decision, expected, mode) in planDecisions {
            let plan = QueuedApproval(id: UUID(), fd: answerPipe[1], sessionId: "plan", pillId: "integration_claude",
                projectName: "Plan project", cwd: "/plan", tool: "ExitPlanMode", command: "Ship the change",
                inputKey: "plan", hostApp: "com.apple.Terminal")
            assert(server.approvals.enqueue(plan) == .accepted)
            server.showApprovalHead()
            server.sendApprovalDecision(decision, for: answered.id)
            assert(server.approvals.head?.id == plan.id)
            server.sendApprovalDecision(decision, for: plan.id)
            var count = -1
            for _ in 0..<100 {
                count = read(answerPipe[0], &answerBytes, answerBytes.count)
                if count > 0 { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            assert(count > 0)
            let reply = try! JSONSerialization.jsonObject(with: Data(answerBytes.prefix(count))) as! [String: String]
            assert(reply["permissionDecision"] == expected && reply["mode"] == mode)
            assert(RecapStore.shared.decisions.last == (decision == "plan_change" ? "deny" : "allow"))
            assert(server.approvals.isEmpty && state.pendingApproval == nil && server.codexApprovals.isEmpty)
        }
        assert(ClaudeHost.activated == ["com.apple.Terminal"])
        print("PASS actual HookServer: display/identity handoff, mixed socket/native FIFO, bounded multiple native approvals, captured UUID/question ID, socket question fallback, stale turn/read-only denial, exact request cleanup, phone fingerprint, plan card decisions")
    }
}
@main enum Check { @MainActor static func main() async { await HookServer.check() } }
''')
PY
swiftc -parse-as-library -swift-version 6 NotchBuddy/Sources/App/ApprovalQueue.swift \
    NotchBuddy/Sources/App/QuestionQueue.swift NotchBuddy/Sources/App/SessionBoard.swift \
    NotchBuddy/Sources/App/PillSessionRegistry.swift NotchBuddy/Sources/App/AskQuestion.swift \
    "$task_tmp/Check.swift" -o "$task_tmp/check"
"$task_tmp/check"
