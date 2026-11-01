#if !APPSTORE
import Foundation

/// Adapts only notifications from Coucou's connection; external hooks keep their own transport.
@MainActor
final class CodexEventAdapter {
    static let shared = CodexEventAdapter()
    private var observer: UUID?
    private var threads: [String: (root: String, cwd: String, path: String?)] = [:]
    private var completedItems = Set<String>()
    private var finalMessage = ""
    private var turnOpen = false
    private var turnPlan: CodexTurnPlan?
    private var turnDiffs = CodexTurnDiffState()

    func start() {
        guard observer == nil else { return }
        observer = CodexConnection.shared.observe { [weak self] method, params, id in
            self?.receive(method: method, params: params, id: id)
        }
    }

    func registerThread(_ thread: [String: Any]) {
        guard let id = thread["id"] as? String, let cwd = thread["cwd"] as? String,
              CodexChatService.shared.owns(threadId: id) else { return }
        threads[id] = (thread["sessionId"] as? String ?? id, cwd, thread["path"] as? String)
        emit("SessionStart", threadId: id, params: [:])
    }

    func unregisterThread(_ id: String) {
        guard threads[id] != nil else { return }
        HookServer.shared.resolveCodexRequests(threadId: id)
        emit("SessionEnd", threadId: id, params: [:])
        threads.removeValue(forKey: id)
        if turnPlan?.threadId == id { turnOpen = false; turnPlan = nil; turnDiffs = CodexTurnDiffState() }
        if AppState.shared.codexTurnPlan?.threadId == id { AppState.shared.codexTurnPlan = nil }
    }

    func isManagedHookSession(_ sessionId: String) -> Bool {
        threads.contains { CodexChatService.shared.owns(threadId: $0.key) && $0.key == sessionId }
    }

    private func receive(method: String, params: [String: Any], id: Any?) {
        let server = HookServer.shared
        if method == "$connection/disconnected" {
            server.resolveCodexRequests()
            for threadId in Array(threads.keys) { unregisterThread(threadId) }
            completedItems.removeAll()
            if let index = AppState.shared.tasks.firstIndex(where: { $0.pill == "agent_codex" && $0.codexManaged }) {
                AppState.shared.tasks[index].codexManaged = false
                AppState.shared.tasks[index].state = .idle
            }
            return
        }
        if let id {
            server.receiveCodexRequest(method: method, params: params, id: id)
            return
        }
        if method == "serverRequest/resolved" {
            if let request = params["requestId"] { server.resolveCodexRequests(requestId: request) }
            return
        }
        // Registration uses the successful thread/start response after ownership is fixed.
        if method == "thread/started" { return }
        guard let threadId = params["threadId"] as? String, threads[threadId] != nil,
              CodexChatService.shared.owns(threadId: threadId) else { return }
        let turn = params["turn"] as? [String: Any] ?? [:]
        let turnId = params["turnId"] as? String ?? turn["id"] as? String ?? ""
        // An old turn's completion must never dismiss or overwrite a new request/turn.
        if method == "turn/started" {
            guard CodexChatService.shared.isBusy, !turnId.isEmpty,
                  turnId != CodexChatService.shared.previousTurnId else { return }
            if let observed = CodexChatService.shared.turnId, observed != turnId { return }
        }
        if method != "turn/started", method != "thread/closed", method != "thread/archived" {
            guard let observed = CodexChatService.shared.turnId, observed == turnId else { return }
        }
        var diffs: [FileDiff] = []
        switch method {
        case "turn/started":
            server.resolveCodexRequests(threadId: threadId)
            completedItems.removeAll(); finalMessage = ""
            turnOpen = true
            turnPlan = CodexTurnPlan(threadId: threadId, turnId: turnId)
            turnDiffs = CodexTurnDiffState()
            if AppState.shared.codexTurnPlan?.threadId == threadId { AppState.shared.codexTurnPlan = nil }
            emit("UserPromptSubmit", threadId: threadId, params: params, turnId: turnId)
        case "item/started", "item/completed":
            guard let item = params["item"] as? [String: Any], let type = item["type"] as? String else { return }
            let done = method == "item/completed"
            let key = "\(threadId)/\(turnId)/\(item["id"] as? String ?? "")"
            if done, !completedItems.insert(key).inserted { return }
            let command = item["command"] as? String ?? ""
            switch type {
            case "commandExecution":
                emit(done ? "PostToolUse" : "PreToolUse", threadId: threadId, params: params, turnId: turnId,
                     extra: ["tool_name": "Bash", "tool_input": ["command": command], "tool_response": ["exit_code": item["exitCode"] as? Int ?? 0, "status": item["status"] as? String ?? ""]])
            case "fileChange":
                if done, item["status"] as? String == "completed" {
                    guard turnOpen, turnPlan?.threadId == threadId, turnPlan?.turnId == turnId else { return }
                    diffs = turnDiffs.recordItem(item["changes"] as? [[String: Any]] ?? [], cwd: threads[threadId]!.cwd, itemId: item["id"] as? String ?? "")
                    server.reconcileCodexDiffs(turnDiffs.files, threadId: threadId, turnId: turnId, moves: turnDiffs.moveSources)
                } else if !done {
                    if turnOpen { turnDiffs.itemStarted(item["id"] as? String ?? "") }
                    emit("PreToolUse", threadId: threadId, params: params, turnId: turnId,
                         extra: ["tool_name": "apply_patch", "tool_input": [:]])
                } else if item["status"] as? String == "failed" {
                    emit("PostToolUse", threadId: threadId, params: params, turnId: turnId,
                         extra: ["tool_response": ["success": false]])
                }
            case "webSearch":
                emit(done ? "PostToolUse" : "PreToolUse", threadId: threadId, params: params, turnId: turnId,
                     extra: ["tool_name": "WebSearch", "tool_input": ["query": (item["action"] as? [String: Any])?["query"] as? String ?? item["query"] as? String ?? ""]])
                if !done { server.updateCodexActivity(.searching, threadId: threadId, turnId: turnId) }
            case "collabAgentToolCall":
                emit(done ? "SubagentStop" : "SubagentStart", threadId: threadId, params: params, turnId: turnId)
            case "agentMessage":
                if done, item["phase"] as? String != "commentary", let text = item["text"] as? String {
                    finalMessage = String(text.prefix(24_000))
                }
            case "plan":
                if done, turnOpen, let text = item["text"] as? String, turnPlan?.threadId == threadId, turnPlan?.turnId == turnId {
                    turnPlan?.text = String(text.prefix(8000))
                    publishPlan(threadId: threadId, turnId: turnId)
                }
            case "reasoning": if !done { server.updateCodexActivity(.thinking, threadId: threadId, turnId: turnId) }
            default: break
            }
        case "turn/plan/updated":
            guard turnOpen, turnPlan?.threadId == threadId, turnPlan?.turnId == turnId else { return }
            turnPlan?.update(params)
            publishPlan(threadId: threadId, turnId: turnId)
        case "turn/diff/updated":
            guard turnOpen, turnPlan?.threadId == threadId, turnPlan?.turnId == turnId,
                  let text = params["diff"] as? String,
                  turnDiffs.updateSnapshot(text, cwd: threads[threadId]!.cwd) else { return }
            diffs = turnDiffs.files
            server.reconcileCodexDiffs(diffs, threadId: threadId, turnId: turnId, moves: turnDiffs.moveSources)
        case "turn/completed":
            turnOpen = false
            server.resolveCodexRequests(threadId: threadId)
            let status = turn["status"] as? String ?? ""
            guard ["completed", "failed", "interrupted"].contains(status) else {
                showError(["message": String(localized: "codex.turn-status-unknown", defaultValue: "Codex returned an unknown turn status. Update Codex and try again.")], threadId: threadId)
                return
            }
            let error = turn["error"] as? [String: Any] ?? (status == "failed" ? [:] : nil)
            let final = (turn["items"] as? [[String: Any]] ?? []).last(where: { $0["type"] as? String == "agentMessage" && $0["phase"] as? String != "commentary" })?["text"] as? String ?? finalMessage
            var extra: [String: Any] = ["last_assistant_message": final]
            if let error { extra["error"] = error }
            emit(status == "interrupted" ? "Interrupt" : status == "failed" || error != nil ? "StopFailure" : "Stop", threadId: threadId, params: params, turnId: turnId,
                 extra: extra)
            if let error { showError(error, threadId: threadId) }
        case "error":
            if let error = params["error"] as? [String: Any] { showError(error, threadId: threadId) }
        case "thread/closed", "thread/archived":
            unregisterThread(threadId)
        default: break
        }
        #if PHONE_LINK
        TurnRecorder.shared.recordCodex(method: method, params: params, diffs: diffs)
        #endif
    }

    /// A native session can become visible after its last plan event while another row was shown.
    func refreshDisplay(threadId: String, turnId: String) {
        guard turnPlan?.threadId == threadId, turnPlan?.turnId == turnId,
              CodexChatService.shared.owns(threadId: threadId) else { return }
        publishPlan(threadId: threadId, turnId: turnId)
    }

    private func publishPlan(threadId: String, turnId: String) {
        guard AppState.shared.tasks.contains(where: {
            $0.pill == "agent_codex" && $0.codexManaged && $0.codexThreadId == threadId && $0.codexTurnId == turnId
        }) else { return }
        AppState.shared.codexTurnPlan = turnPlan?.isEmpty == false ? turnPlan : nil
    }

    private func showError(_ error: [String: Any], threadId: String) {
        let data = (try? JSONSerialization.data(withJSONObject: error)) ?? Data()
        let limited = String(data: data, encoding: .utf8)?.lowercased().contains("usagelimitexceeded") == true
        let state = AppState.shared
        guard let index = state.tasks.firstIndex(where: {
            $0.pill == "agent_codex" && $0.codexManaged && $0.codexThreadId == threadId
        }) else { return }
        state.updateTask(id: state.tasks[index].id, state: limited ? .ratelimit : .error)
        let message = (error["message"] as? String).flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        } ?? String(localized: "codex.turn-failed", defaultValue: "Codex could not complete this turn.")
        state.noteMessage = message
        state.tasks[index].finalLine = DiffEngine.toOneLine(message)
    }

    private func emit(_ name: String, threadId: String, params: [String: Any], turnId: String = "", extra: [String: Any] = [:]) {
        guard let thread = threads[threadId] else { return }
        var payload: [String: Any] = ["coucou_agent": "codex", "coucou_managed": true,
            "session_id": thread.root, "thread_id": threadId, "cwd": thread.cwd,
            "turn_id": turnId, "bundle_id": Bundle.main.bundleIdentifier ?? ""]
        if let path = thread.path { payload["rollout_path"] = path }
        payload.merge(extra) { _, new in new }
        HookServer.shared.receiveCodexEvent(name: name, payload: payload)
    }
}
#endif
