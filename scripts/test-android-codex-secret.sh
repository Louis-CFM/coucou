#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/Check.swift" <<'PY'
from pathlib import Path
import sys
source = Path('NotchBuddy/Sources/App/AndroidLink/AndroidLinkService.swift').read_text()
host = source[source.index('final class AndroidLinkAppHost:'):source.index('// MARK: Service')]
start = source.index('    static func question(from waiting:')
end = source.index('    static func usage(', start)
method = source[start:end]
fixture = r'''import Foundation
struct ApprovalInfo { var id: UUID; var tool: String }
@MainActor final class AppState {
    static let shared = AppState()
    var pendingApproval: ApprovalInfo?
    var waitingQuestions: [QueuedQuestion] = []
}
@MainActor final class HookServer {
    static let shared = HookServer()
    var answered: [(UUID, [String: Any])] = []
    func sendApprovalDecision(_ value: String, for id: UUID) {}
    func sendQuestionAnswers(_ answers: [String: Any], for id: UUID) { answered.append((id, answers)) }
}
@MainActor enum AndroidLinkService {
    nonisolated static func log(_ message: String) {}
METHOD
}
HOST
@main enum Check {
    @MainActor static func main() async {
        let option = AskQuestionOption(label: "Allowed", description: "")
        let publicItem = AskQuestionItem(question: "Choose", header: "", options: [option], multiSelect: false, id: "native", isOther: true)
        let secretItem = AskQuestionItem(question: "Secret", header: "", options: [option], multiSelect: false, id: "secret", isSecret: true)
        func entry(_ id: UUID, _ items: [AskQuestionItem]) -> QueuedQuestion {
            QueuedQuestion(id: id, fd: -1, sessionId: "thread", pillId: "agent_codex", projectName: "project", cwd: "/project", question: AskQuestion(questions: items))
        }
        let secretID = UUID(), visibleID = UUID(), freeID = UUID()
        let secret = entry(secretID, [publicItem, secretItem])
        let visible = entry(visibleID, [publicItem])
        let free = entry(freeID, [AskQuestionItem(question: "Text", header: "", options: [], multiSelect: false, id: "free", isOther: true)])
        assert(AndroidLinkService.question(from: [secret]) == nil)
        assert(AndroidLinkService.question(from: [free]) == nil)
        let offered = AndroidLinkService.question(from: [secret, free, visible])!
        assert(offered.requestId == visibleID.uuidString && offered.questions.count == 1)
        assert(AndroidLinkHub.picksMatch(offered.questions, picks: [["Allowed"]]))
        assert(!AndroidLinkHub.picksMatch(offered.questions, picks: [["unlisted text"]]))
        assert(!AndroidLinkHub.picksMatch(offered.questions, picks: [["Allowed", "Allowed"]]))
        assert(!AndroidLinkHub.picksMatch(offered.questions, picks: []))
        let host = AndroidLinkAppHost(), hub = AndroidLinkHub(host: host)
        let fp = AndroidLinkProtocol.fingerprint(pillId: offered.pillId, sessionId: offered.sessionId, tool: "AskUserQuestion", command: "Choose", inputKey: offered.requestId)
        AppState.shared.waitingQuestions = [visible]
        hub.publishQuestion(offered, now: 10)
        assert(hub.answer(fingerprint: fp, picks: [["unlisted text"]], now: 11) == .invalid)
        assert(hub.answer(fingerprint: fp, picks: [["Allowed"]], now: 11) == .applied)
        // The state changes before the host's main-actor task runs: same UUID, now secret.
        AppState.shared.waitingQuestions = [entry(visibleID, [secretItem])]
        for _ in 0..<30 { await Task.yield() }
        assert(HookServer.shared.answered.isEmpty)
        AppState.shared.waitingQuestions = [secret, visible]
        host.answer(requestId: secretID.uuidString, picks: [["Allowed"], ["Allowed"]])
        host.answer(requestId: UUID().uuidString, picks: [["Allowed"]])
        host.answer(requestId: visibleID.uuidString, picks: [["unlisted text"]])
        host.answer(requestId: visibleID.uuidString, picks: [])
        for _ in 0..<30 { await Task.yield() }
        assert(HookServer.shared.answered.isEmpty)
        host.answer(requestId: visibleID.uuidString, picks: [["Allowed"]])
        for _ in 0..<30 { await Task.yield() }
        assert(HookServer.shared.answered.count == 1 && HookServer.shared.answered[0].0 == visibleID)
        let native = HookServer.shared.answered[0].1["native"] as? [String: [String]]
        assert(native?["answers"] == ["Allowed"])
        print("PASS actual Android question/host: mixed secret exclusion, free text limits, valid choices, stale UUID, forged picks and main-actor race")
    }
}
'''
Path(sys.argv[1]).write_text(fixture.replace('METHOD', method).replace('HOST', host))
PY
link=NotchBuddy/Sources/App/AndroidLink
swiftc -swift-version 6 -parse-as-library "$link/AndroidLinkProtocol.swift" "$link/AndroidLinkHub.swift" \
    NotchBuddy/Sources/App/AskQuestion.swift NotchBuddy/Sources/App/QuestionQueue.swift "$test_dir/Check.swift" -o "$test_dir/check"
"$test_dir/check"
