#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d)
trap 'rm -rf "$task_tmp"' EXIT
# Actual parser/HookServer queues, isolated UI/RPC and deterministic socket timers.
python3 - "$task_tmp/Check.swift" <<'PY'
from pathlib import Path
import runpy
import sys
shared = runpy.run_path('scripts/codex-hook-test-fixture.py')
Path(sys.argv[1]).write_text(shared['fixture']() + shared['socket_helpers']() + r'''
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
        let nine = (1...9).map { ["label": "Choice \($0)"] }
        assert(AskQuestion.parseCodexPlugin(["questions": [["id": "x", "question": "Q", "options": nine]]]) != nil)
        assert(AskQuestion.parseCodexPlugin(["questions": [["id": "x", "question": "Q", "options": nine + [["label": "Ten"]]]]]) == nil)


        let payload: [String: Any] = ["coucou_agent": "codex", "session_id": "plugin", "cwd": "/fixture/project", "bundle_id": "com.openai.codex"]
        let answers = AskQuestion.buildAnswers(questions: plugin.questions, selections: [["Two"], ["Free text"], ["fixture-only"]])
        func currentID() -> UUID { UUID(uuidString: state.pendingQuestion!.requestId!)! }
        let first = sockets()
        server.processQuestionRequest(fd: first[0], parsed: plugin, payload: payload)
        let firstID = currentID(), firstSource = server.questionSources[currentID()]!, firstTimeout = server.timeouts.last!
        assert(state.pendingQuestion!.isCodexPlugin && state.pendingQuestion!.threadId == nil && state.pendingQuestion!.projectName == "project"
            && server.questions.head?.fd == first[0] && state.view == .question)
        // A retry replaces only this session, preserving a distinct UUID even when fd is reused.
        let replacement = sockets()
        server.processQuestionRequest(fd: replacement[0], parsed: plugin, payload: payload)
        let replacementID = currentID()
        let replaced = await response(first[1]); await closed(first[0])
        assert(replaced["permissionDecision"] as? String == "ask" && replacementID != firstID && server.questions.count == 1)
        firstSource.fire(); firstTimeout()
        server.sendQuestionAnswers(answers, for: firstID); server.sendQuestionAsk(for: firstID); server.releaseQuestionFD(for: firstID)
        server.sendQuestionAnswers(answers)
        noReply(replacement[1]); assert(server.questions.head?.id == replacementID)
        server.sendQuestionAnswers(answers, for: replacementID)
        let firstReply = await response(replacement[1]); await closed(replacement[0])
        assert(firstReply["permissionDecision"] as? String == "answer")
        let values = firstReply["answers"] as! [String: [String: [String]]]
        assert(values["choice"]?["answers"] == ["Two"] && values["free"]?["answers"] == ["Free text"] && values["secret"]?["answers"] == ["fixture-only"])
        assert(state.pendingQuestion == nil && server.sessions.liveCount(pill: "agent_codex") == 0)
        let second = sockets(reusing: first[0])
        server.processQuestionRequest(fd: second[0], parsed: plugin, payload: payload)
        let secondID = currentID()
        firstSource.fire(); firstTimeout(); server.sendQuestionAsk(for: firstID); server.releaseQuestionFD(for: firstID)
        noReply(second[1]); assert(server.questions.head?.id == secondID)
        server.timeouts.last!()
        let timeoutReply = await response(second[1]); await closed(second[0])
        assert(timeoutReply["permissionDecision"] as? String == "ask" && state.pendingQuestion == nil)
        let eof = sockets()
        server.processQuestionRequest(fd: eof[0], parsed: plugin, payload: payload)
        server.questionSources[currentID()]!.fire(); await closed(eof[0])
        var byte: UInt8 = 0
        assert(read(eof[1], &byte, 1) == 0 && state.pendingQuestion == nil); close(eof[1])
        assert(server.sessions.liveCount(pill: "agent_codex") == 0)
        for release in [false, true] {
            let pair = sockets()
            server.processQuestionRequest(fd: pair[0], parsed: plugin, payload: payload)
            if release { server.releaseQuestionFD(for: currentID()) } else { server.sendQuestionAsk(for: currentID()) }
            let reply = await response(pair[1]); await closed(pair[0])
            assert(reply["permissionDecision"] as? String == "ask" && state.pendingQuestion == nil && server.sessions.liveCount(pill: "agent_codex") == 0)
        }
        // Independent plugin and legacy Claude questions queue; neither steals the other's socket.
        let legacy = AskQuestion.parse(toolInput: ["questions": [["question": "Legacy?", "options": [["label": "Yes"], ["label": "No"]]]]])!
        let claude = sockets()
        server.processQuestionRequest(fd: claude[0], parsed: legacy, payload: ["session_id": "claude", "bundle_id": "com.microsoft.VSCode"])
        let claudeID = currentID()
        let queuedPlugin = sockets()
        server.processQuestionRequest(fd: queuedPlugin[0], parsed: plugin, payload: payload)
        let pluginID = server.questions.entries.last!.id
        assert(server.questions.count == 2 && currentID() == claudeID && !state.pendingQuestion!.isCodexPlugin)
        noReply(queuedPlugin[1])
        server.sendQuestionAnswers(AskQuestion.buildAnswers(questions: legacy.questions, selections: [["Yes"]]), for: claudeID)
        let claudeReply = await response(claude[1]); await closed(claude[0])
        assert((claudeReply["answers"] as? [String: String])?["Legacy?"] == "Yes" && currentID() == pluginID)
        server.sendQuestionAsk(for: pluginID)
        _ = await response(queuedPlugin[1]); await closed(queuedPlugin[0])
        assert(server.sessions.liveCount(pill: "integration_claude") == 1 && server.sessions.workingCount(pill: "integration_claude") == 1)
        // Approval has card priority; a hidden question stays queued and resumes afterward.
        let queued = QueuedApproval(id: UUID(), fd: -1, sessionId: "approval", pillId: "integration_claude", projectName: "Fixture", cwd: "/fixture", tool: "Bash", command: "pwd", inputKey: "")
        assert(server.approvals.enqueue(queued) == .accepted); server.showApprovalHead()
        let approvalQuestion = sockets()
        server.processQuestionRequest(fd: approvalQuestion[0], parsed: plugin, payload: payload)
        let waitingID = server.questions.head!.id
        assert(state.pendingQuestion == nil && server.questions.count == 1 && state.view == .approval)
        server.releaseQuestionFD(for: waitingID)
        assert(server.questions.count == 1); noReply(approvalQuestion[1])
        server.removeApproval(id: queued.id)
        assert(currentID() == waitingID && state.view == .question)
        // A late EOF cannot dismiss a newer real approval or clear its task state.
        let newer = QueuedApproval(id: UUID(), fd: -1, sessionId: "new-approval", pillId: "agent_codex", projectName: "New", cwd: "/new", tool: "Bash", command: "pwd", inputKey: "")
        assert(server.approvals.enqueue(newer) == .accepted); server.showApprovalHead()
        server.questionSources[waitingID]!.fire(); await closed(approvalQuestion[0])
        assert(read(approvalQuestion[1], &byte, 1) == 0); close(approvalQuestion[1])
        assert(state.pendingQuestion == nil && state.pendingApproval?.id == newer.id && state.view == .approval && state.isPinned)
        server.removeApproval(id: newer.id)
        // Native and plugin requests share UI queue IDs, retaining their distinct transports.
        CodexChatService.shared.threadId = "native"
        let nativeParams: [String: Any] = ["threadId": "native", "turnId": "turn", "questions": [rows[0]]]
        let native = AskQuestion.parseCodex(nativeParams, requestId: "[7]")!
        assert(!native.isCodexPlugin && native.threadId == "native" && native.turnId == "turn")
        let display = PillSessionRegistry.Display(session: "native", projectName: "Native", cwd: "/native", codexThreadId: "native", codexTurnId: "turn", codexManaged: true)
        server.sessions.note(pill: "agent_codex", display: display, working: true)
        server.record(pill: "agent_codex", session: "native", raw: "native", title: "Native") { $0.state = .working }
        server.receiveCodexRequest(method: "item/tool/requestUserInput", params: nativeParams, id: 7)
        let nativeID = currentID()
        let nativePlugin = sockets()
        server.processQuestionRequest(fd: nativePlugin[0], parsed: plugin, payload: payload)
        let nativePluginID = server.questions.entries.last!.id
        server.sendQuestionAnswers(answers, for: firstID)
        assert(CodexConnection.shared.answers.isEmpty)
        server.sendQuestionAnswers(answers, for: nativeID)
        assert(CodexConnection.shared.answers.count == 1 && CodexConnection.shared.answers[0].id == 7 && currentID() == nativePluginID)
        server.sendQuestionAsk(for: nativePluginID); _ = await response(nativePlugin[1]); await closed(nativePlugin[0])
        assert(server.sessions.display(pill: "agent_codex", session: "native")?.codexManaged == true && server.sessions.display(pill: "agent_codex", session: "plugin") == nil)
        server.receiveCodexRequest(method: "item/tool/requestUserInput", params: nativeParams, id: 8)
        let staleNativeID = currentID(); CodexChatService.shared.turnId = "next-turn"
        server.sendQuestionAnswers(answers, for: staleNativeID)
        assert(CodexConnection.shared.answers.count == 1 && server.codexQuestions.isEmpty && state.pendingQuestion == nil)
        let socketNative = sockets()
        server.processQuestionRequest(fd: socketNative[0], parsed: native, payload: payload)
        server.sendQuestionAnswers(AskQuestion.buildAnswers(questions: native.questions, selections: [["One"]]), for: currentID())
        let socketNativeReply = await response(socketNative[1]); await closed(socketNative[0])
        assert(((socketNativeReply["answers"] as? [String: [String: [String]]])?["choice"])?["answers"] == ["One"] && CodexConnection.shared.answers.count == 1)
        let mirror = sockets()
        server.processQuestionRequest(fd: mirror[0], parsed: plugin, payload: ["coucou_agent": "codex", "session_id": "native-hook"])
        let mirrorReply = await response(mirror[1]); await closed(mirror[0])
        assert(mirrorReply["permissionDecision"] as? String == "ask" && state.pendingQuestion == nil)
        let validSession = UUID().uuidString
        let framed: [String: Any] = ["coucou_kind": "codex_mcp_question", "coucou_agent": "codex",
            "session_id": validSession, "request_id": UUID().uuidString,
            "cwd": CommandLine.arguments[1], "tool_input": input, "padding": String(repeating: "x", count: 6000)]
        // Multiple recv chunks and a second line must still display exactly the first request.
        let framedSocket = await packet(framed, suffix: "{\"coucou_kind\":\"ignored-second-line\"}\n")
        await displayed(session: validSession)
        assert(state.pendingQuestion!.isCodexPlugin && state.pendingQuestion!.threadId == nil
            && state.pendingQuestion!.turnId == nil && server.questions.head?.fd == framedSocket[0])
        let framedID = UUID(uuidString: state.pendingQuestion!.requestId!)!
        let permissionSocket = await packet(["hook_event_name": "PermissionRequest", "session_id": "other",
            "tool_name": "Bash", "bundle_id": "com.microsoft.VSCode"])
        let permissionReply = await response(permissionSocket[1]); await closed(permissionSocket[0])
        assert(permissionReply["permissionDecision"] as? String == "ask"
            && state.pendingQuestion?.requestId == framedID.uuidString && state.isPinned && state.view == .question)
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
        server.sendQuestionAsk(for: UUID(uuidString: state.pendingQuestion!.requestId!)!)
        let boundaryReply = await response(boundarySocket[1]); await closed(boundarySocket[0])
        assert(boundaryReply["permissionDecision"] as? String == "ask" && state.pendingQuestion == nil)
        let invalidFields: [(String, Any)] = [("session_id", "bad-uuid"), ("request_id", "bad-uuid"),
            ("coucou_agent", "claude"), ("cwd", "relative"), ("cwd", "/missing-coucou-fixture-directory"),
            ("cwd", CommandLine.arguments[1] + "/Check.swift"), ("cwd", "/tmp\0invalid"),
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
        print("PASS actual Codex plugin/parser/client/FIFO: bounds/spoof rejection, fragmented framing, UUID/fd reuse, retry, native and legacy routing, approval priority, timeout/EOF, sibling ownership")
    }
}
@main enum Check { @MainActor static func main() async { await HookServer.check() } }
''')
PY
swiftc -parse-as-library -swift-version 6 NotchBuddy/Sources/App/AskQuestion.swift \
    NotchBuddy/Sources/App/ApprovalQueue.swift NotchBuddy/Sources/App/QuestionQueue.swift \
    NotchBuddy/Sources/App/SessionBoard.swift NotchBuddy/Sources/App/PillSessionRegistry.swift \
    "$task_tmp/Check.swift" -o "$task_tmp/check"
"$task_tmp/check" "$task_tmp"
