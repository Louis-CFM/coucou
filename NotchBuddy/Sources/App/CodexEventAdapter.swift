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

    func isManagedHookSession(_ sessionId: String) -> Bool {
        threads.contains { CodexChatService.shared.owns(threadId: $0.key) && $0.key == sessionId }
    }

    private func receive(method: String, params: [String: Any], id: Any?) {
        let server = HookServer.shared
        if method == "$connection/disconnected" {
            server.resolveCodexRequests()
            threads.removeAll(); completedItems.removeAll()
            if let index = AppState.shared.tasks.firstIndex(where: { $0.id == "agent_codex" && $0.codexManaged }) {
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
        if method != "turn/started", let current = AppState.shared.tasks.first(where: { $0.id == "agent_codex" }),
           current.codexThreadId == threadId, let observed = current.codexTurnId,
           !turnId.isEmpty, observed != turnId { return }
        var diffs: [FileDiff] = []
        switch method {
        case "turn/started":
            server.resolveCodexRequests(threadId: threadId)
            completedItems.removeAll(); finalMessage = ""
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
                    for change in item["changes"] as? [[String: Any]] ?? [] {
                        guard let originalPath = change["path"] as? String, let text = change["diff"] as? String else { continue }
                        let kind = change["kind"] as? [String: Any]
                        let path = kind?["move_path"] as? String ?? originalPath
                        let parsed = DiffEngine.fromUnifiedDiff(text, path: path)
                        if parsed.isEmpty, text.isEmpty, let kind,
                           ["add", "delete", "update"].contains(kind["type"] as? String ?? "") {
                            diffs.append(FileDiff(path: path, added: 0, removed: 0, hunks: [], tooLarge: false, isNewFile: kind["type"] as? String == "add"))
                        } else { diffs += parsed }
                    }
                    for diff in diffs { server.recordCodexDiff(diff, sessionId: threadId) }
                } else if !done {
                    emit("PreToolUse", threadId: threadId, params: params, turnId: turnId,
                         extra: ["tool_name": "apply_patch", "tool_input": [:]])
                } else if item["status"] as? String == "failed" {
                    emit("PostToolUse", threadId: threadId, params: params, turnId: turnId,
                         extra: ["tool_response": ["success": false]])
                }
            case "webSearch":
                emit(done ? "PostToolUse" : "PreToolUse", threadId: threadId, params: params, turnId: turnId,
                     extra: ["tool_name": "WebSearch", "tool_input": ["query": (item["action"] as? [String: Any])?["query"] as? String ?? item["query"] as? String ?? ""]])
                if !done { AppState.shared.updateTask(id: "agent_codex", state: .searching) }
            case "collabAgentToolCall":
                emit(done ? "SubagentStop" : "SubagentStart", threadId: threadId, params: params, turnId: turnId)
            case "agentMessage":
                if done, item["phase"] as? String != "commentary", let text = item["text"] as? String {
                    finalMessage = String(text.prefix(24_000))
                }
            case "reasoning": if !done { AppState.shared.updateTask(id: "agent_codex", state: .thinking) }
            default: break
            }
        case "turn/diff/updated":
            diffs = DiffEngine.fromUnifiedDiff(params["diff"] as? String ?? "")
        case "turn/completed":
            server.resolveCodexRequests(threadId: threadId)
            let status = turn["status"] as? String ?? ""
            guard ["completed", "failed", "interrupted"].contains(status) else {
                showError(["message": String(localized: "codex.turn-status-unknown", defaultValue: "Codex returned an unknown turn status. Update Codex and try again.")], threadId: threadId)
                return
            }
            let error = turn["error"] as? [String: Any]
            let final = (turn["items"] as? [[String: Any]] ?? []).last(where: { $0["type"] as? String == "agentMessage" && $0["phase"] as? String != "commentary" })?["text"] as? String ?? finalMessage
            emit(status == "interrupted" ? "Interrupt" : status == "failed" || error != nil ? "StopFailure" : "Stop", threadId: threadId, params: params, turnId: turnId,
                 extra: ["last_assistant_message": final])
            if let error { showError(error, threadId: threadId) }
        case "error":
            if let error = params["error"] as? [String: Any] { showError(error, threadId: threadId) }
        case "thread/closed", "thread/archived":
            server.resolveCodexRequests(threadId: threadId)
            emit("SessionEnd", threadId: threadId, params: params)
            threads.removeValue(forKey: threadId)
        default: break
        }
        #if PHONE_LINK
        TurnRecorder.shared.recordCodex(method: method, params: params, diffs: diffs)
        #endif
    }

    private func showError(_ error: [String: Any], threadId: String) {
        let data = (try? JSONSerialization.data(withJSONObject: error)) ?? Data()
        let limited = String(data: data, encoding: .utf8)?.lowercased().contains("usagelimitexceeded") == true
        let state = AppState.shared
        state.updateTask(id: "agent_codex", state: limited ? .ratelimit : .error)
        state.noteMessage = error["message"] as? String ?? String(localized: "codex.turn-failed", defaultValue: "Codex could not complete this turn.")
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
