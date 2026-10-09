#if PHONE_LINK
import AppKit
import CloudKit

// MARK: - The last turn, for the iPhone
//
// Built from the hook events HookServer already receives: UserPromptSubmit
// starts a turn, Pre/PostToolUse add actions (commands with their output,
// edits with their diff), Stop adds the final answer. One encrypted `Turn`
// record per session pill, replaced at each turn; nothing else is kept.
// Runs only while the iPhone sync is on; no timer.

@MainActor
final class TurnRecorder {
    static let shared = TurnRecorder()

    private lazy var container = CKContainer(identifier: CloudProbe.containerID)
    private var database: CKDatabase { container.privateCloudDatabase }
    private var running = false
    private var turns: [String: TurnSnapshot] = [:]
    private var dirty: Set<String> = []
    private var flushTask: Task<Void, Never>?
    private var nativeActions: [String: Int] = [:]
    private var completedNativeItems = Set<String>()

    // Size limits: a turn stays well under CloudKit's 1 MB per record.
    private let maxActions = 200
    private let maxLinesPerFile = 600
    private let maxTotalLines = 4000
    private let maxOutput = 1500
    private let maxFinal = 12_000

    /// The Claude Code session last seen on a pill and its folder, for
    /// instructions sent from the iPhone (InstructionRunner).
    func lastSession(for pillId: String) -> (sessionId: String, cwd: String)? {
        guard let info = sessions[pillId], !info.sessionId.isEmpty, !info.cwd.isEmpty else { return nil }
        return info
    }
    private var sessions: [String: (sessionId: String, cwd: String)] = [:]

    func start() {
        running = true
        log("turn recorder on")
    }

    func stop() {
        running = false
        flushTask?.cancel(); flushTask = nil
        let ids = turns.keys.map {
            CKRecord.ID(recordName: TurnSnapshot.recordName(for: $0), zoneID: SessionSnapshot.zoneID)
        }
        turns = [:]
        nativeActions = [:]
        completedNativeItems = []
        dirty = []
        if !ids.isEmpty {
            Task { _ = try? await database.modifyRecords(saving: [], deleting: ids, savePolicy: .changedKeys, atomically: false) }
        }
    }

    /// Called by HookServer for every event of a session pill.
    func record(event: String, payload: [String: Any], pillId: String) {
        guard running, PillCatalog.isSession(pillId) else { return }
        let sessionId = payload["session_id"] as? String ?? payload["conversation_id"] as? String ?? ""
        let cwd = payload["cwd"] as? String ?? ""
        let now = Date()
        if pillId == "agent_codex", let task = AppState.shared.tasks.first(where: { $0.id == pillId }), task.codexManaged,
           sessionId == task.sessionId || sessionId == task.codexThreadId {
            return // The managed connection is authoritative for this same thread.
        }
        if !sessionId.isEmpty, !cwd.isEmpty { sessions[pillId] = (sessionId, cwd) }

        switch event {
        case "UserPromptSubmit":
            let prompt = payload["prompt"] as? String ?? ""
            turns[pillId] = TurnSnapshot(pillId: pillId, sessionId: sessionId,
                                         project: URL(fileURLWithPath: cwd).lastPathComponent,
                                         prompt: String(prompt.prefix(8000)), actions: [], files: [],
                                         finalMessage: "", startedAt: now, endedAt: nil)

        case "PreToolUse":
            let tool = payload["tool_name"] as? String ?? "Tool"
            guard tool != "AskUserQuestion" else { return }
            var turn = current(pillId, sessionId: sessionId, cwd: cwd)
            guard turn.actions.count < maxActions else { return }
            let input = payload["tool_input"] as? [String: Any] ?? [:]
            turn.actions.append(TurnAction(tool: tool, summary: Self.summary(tool: tool, input: input), date: now))
            turns[pillId] = turn

        case "PostToolUse", "PostToolUseFailure":
            let tool = payload["tool_name"] as? String ?? "Tool"
            guard tool != "AskUserQuestion" else { return }
            var turn = current(pillId, sessionId: sessionId, cwd: cwd)
            let input = payload["tool_input"] as? [String: Any] ?? [:]
            let summary = Self.summary(tool: tool, input: input)
            // The matching PreToolUse action, latest first; one is added if it was missed.
            var index = turn.actions.lastIndex { $0.tool == tool && $0.summary == summary && $0.output.isEmpty && $0.fileIndex == nil }
            if index == nil, turn.actions.count < maxActions {
                turn.actions.append(TurnAction(tool: tool, summary: summary, date: now))
                index = turn.actions.count - 1
            }
            guard let index else { return }
            turn.actions[index].failed = event == "PostToolUseFailure" || Self.commandFailed(payload)
            turn.actions[index].output = Self.output(payload, limit: maxOutput)
            if event == "PostToolUse", !turn.actions[index].failed {
                let diffs = tool == "apply_patch" ? DiffEngine.fromCodexPatch(input["command"] as? String ?? "")
                    : Self.fileDiff(tool: tool, input: input).map { [$0] } ?? []
                for diff in diffs {
                    if let fileIndex = append(diff, to: &turn), turn.actions[index].fileIndex == nil {
                        turn.actions[index].fileIndex = fileIndex
                    }
                }
            }
            turns[pillId] = turn

        case "Stop", "StopFailure":
            var turn = current(pillId, sessionId: sessionId, cwd: cwd)
            let final = (payload["last_assistant_message"] as? String) ?? (payload["message"] as? String) ?? ""
            turn.finalMessage = String(final.prefix(maxFinal))
            turn.endedAt = now
            turns[pillId] = turn

        default:
            return
        }
        dirty.insert(pillId)
        scheduleFlush(soon: event == "Stop" || event == "StopFailure" || event == "UserPromptSubmit")
    }

    /// Native events are accepted only for the thread Coucou owns. The raw
    /// request/answer payload is never stored here (in particular secrets).
    func recordCodex(method: String, params: [String: Any], diffs: [FileDiff] = []) {
        guard running, let threadId = params["threadId"] as? String,
              let task = AppState.shared.tasks.first(where: { $0.id == "agent_codex" }),
              task.codexManaged, task.codexThreadId == threadId, let cwd = task.sessionCwd else { return }
        let nativeTurn = params["turn"] as? [String: Any] ?? [:]
        let turnId = params["turnId"] as? String ?? nativeTurn["id"] as? String ?? ""
        guard !turnId.isEmpty else { return }
        let pillId = task.id
        if method == "turn/started", turns[pillId]?.turnId != turnId {
            turns[pillId] = TurnSnapshot(pillId: pillId, sessionId: task.sessionId ?? threadId,
                project: URL(fileURLWithPath: cwd).lastPathComponent, prompt: "", actions: [], files: [],
                finalMessage: "", startedAt: Date(), endedAt: nil, threadId: threadId, turnId: turnId)
            nativeActions = [:]
            completedNativeItems = []
        }
        guard var turn = turns[pillId], turn.threadId == threadId, turn.turnId == turnId else { return }
        let item = params["item"] as? [String: Any] ?? [:]
        let itemId = item["id"] as? String ?? ""
        let type = item["type"] as? String ?? ""
        if method == "item/started" || method == "item/completed" {
            guard !itemId.isEmpty else { return }
            if method == "item/completed", !completedNativeItems.insert(itemId).inserted { return }
            switch type {
            case "userMessage":
                let content = item["content"] as? [[String: Any]] ?? []
                turn.prompt = String(content.compactMap { $0["text"] as? String }.joined(separator: "\n").prefix(8000))
            case "agentMessage":
                if method == "item/completed", item["phase"] as? String != "commentary", let text = item["text"] as? String {
                    turn.finalMessage = String((turn.finalMessage + (turn.finalMessage.isEmpty ? "" : "\n") + text).prefix(maxFinal))
                }
            case "commandExecution", "fileChange", "webSearch", "collabAgentToolCall":
                let tool = type == "commandExecution" ? "Bash" : type == "fileChange" ? "apply_patch" : type == "webSearch" ? "WebSearch" : "Task"
                let action = item["action"] as? [String: Any] ?? [:]
                let summary = item["command"] as? String ?? action["query"] as? String
                    ?? (item["changes"] as? [[String: Any]])?.compactMap { change in
                        (change["kind"] as? [String: Any])?["move_path"] as? String ?? change["path"] as? String
                    }.joined(separator: ", ") ?? tool
                if nativeActions[itemId] == nil, turn.actions.count < maxActions {
                    nativeActions[itemId] = turn.actions.count
                    turn.actions.append(TurnAction(tool: tool, summary: String(summary.prefix(600)), date: Date()))
                }
                if let index = nativeActions[itemId], turn.actions.indices.contains(index), method == "item/completed" {
                    let failed = (item["exitCode"] as? Int).map { $0 != 0 } ?? false
                        || item["status"] as? String == "failed" || item["status"] as? String == "declined"
                    turn.actions[index].failed = failed
                    turn.actions[index].output = String((item["aggregatedOutput"] as? String ?? "").prefix(maxOutput))
                    if !failed {
                        for diff in diffs {
                            if let fileIndex = append(diff, to: &turn), turn.actions[index].fileIndex == nil {
                                turn.actions[index].fileIndex = fileIndex
                            }
                        }
                    }
                }
            default: break
            }
        } else if method == "turn/diff/updated" {
            turn.files = []
            for diff in diffs { append(diff, to: &turn) }
            // Cumulative diffs can reorder files. Resolve links by path again.
            for index in turn.actions.indices where turn.actions[index].tool == "apply_patch" {
                turn.actions[index].fileIndex = turn.files.firstIndex { turn.actions[index].summary.contains($0.path) }
            }
        } else if method == "turn/completed" {
            turn.endedAt = Date()
            if let error = nativeTurn["error"] as? [String: Any], let message = error["message"] as? String {
                turn.finalMessage = String(message.prefix(maxFinal))
            }
        } else if method == "error", let error = params["error"] as? [String: Any], let message = error["message"] as? String {
            turn.finalMessage = String(message.prefix(maxFinal))
        } else { return }
        turns[pillId] = turn
        dirty.insert(pillId)
        scheduleFlush(soon: method == "turn/completed" || method == "turn/started")
    }

    @discardableResult
    private func append(_ diff: FileDiff, to turn: inout TurnSnapshot) -> Int? {
        guard turn.files.count < maxActions else { return nil }
        let used = turn.files.reduce(0) { $0 + $1.lines.count }
        let budget = max(0, min(maxLinesPerFile, maxTotalLines - used))
        turn.files.append(TurnFile(diff: diff, maxLines: budget))
        return turn.files.count - 1
    }

    static func commandFailed(_ payload: [String: Any]) -> Bool {
        let response = payload["tool_response"] as? [String: Any] ?? [:]
        let code = response["exit_code"] as? Int ?? response["exitCode"] as? Int ?? payload["exit_code"] as? Int
        return code.map { $0 != 0 } ?? false
    }

    /// The turn in progress, or a new one when the prompt wasn't seen (Codex, app started mid-turn).
    private func current(_ pillId: String, sessionId: String, cwd: String) -> TurnSnapshot {
        if let turn = turns[pillId], turn.endedAt == nil { return turn }
        return TurnSnapshot(pillId: pillId, sessionId: sessionId,
                            project: URL(fileURLWithPath: cwd).lastPathComponent,
                            prompt: "", actions: [], files: [], finalMessage: "", startedAt: Date(), endedAt: nil)
    }

    // MARK: Writing

    private func scheduleFlush(soon: Bool) {
        if soon { flushTask?.cancel(); flushTask = nil }
        guard flushTask == nil else { return }
        flushTask = Task {
            try? await Task.sleep(for: .seconds(soon ? 0.5 : 2))
            guard !Task.isCancelled else { return }
            flushTask = nil
            await flush()
        }
    }

    private func flush() async {
        let ids = dirty
        dirty = []
        let records = ids.compactMap { id -> CKRecord? in
            guard let turn = turns[id], let json = try? JSONEncoder().encode(turn),
                  let payload = String(data: json, encoding: .utf8) else { return nil }
            let record = CKRecord(recordType: TurnSnapshot.recordType,
                                  recordID: CKRecord.ID(recordName: TurnSnapshot.recordName(for: id),
                                                        zoneID: SessionSnapshot.zoneID))
            record["pillId"] = id
            record["updatedAt"] = Date()
            record.encryptedValues["payload"] = payload
            return record
        }
        guard !records.isEmpty else { return }
        do {
            _ = try await database.modifyRecords(saving: records, deleting: [], savePolicy: .allKeys, atomically: false)
        } catch {
            log("turn publish failed: \(error.localizedDescription)")
        }
    }

    // MARK: Reading the hook payloads

    static func summary(tool: String, input: [String: Any]) -> String {
        let keys = ["command", "file_path", "path", "pattern", "url", "query", "description", "prompt"]
        for key in keys {
            if let value = input[key] as? String, !value.isEmpty { return String(value.prefix(600)) }
        }
        return ""
    }

    /// What a command printed, or the error.
    static func output(_ payload: [String: Any], limit: Int) -> String {
        var text = ""
        if let error = payload["error"] as? String {
            text = error
        } else if let response = payload["tool_response"] as? [String: Any] {
            let stdout = response["stdout"] as? String ?? ""
            let stderr = response["stderr"] as? String ?? ""
            let output = response["output"] as? String ?? response["aggregatedOutput"] as? String ?? ""
            text = [stdout, stderr, output].filter { !$0.isEmpty }.joined(separator: "\n")
        } else if let response = payload["tool_response"] as? String {
            text = response
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "\n…" : trimmed
    }

    static func fileDiff(tool: String, input: [String: Any]) -> FileDiff? {
        guard let path = input["file_path"] as? String else { return nil }
        switch tool {
        case "Edit":
            guard let old = input["old_string"] as? String, let new = input["new_string"] as? String else { return nil }
            return DiffEngine.fromEdit(old: old, new: new, path: path)
        case "MultiEdit":
            guard let edits = input["edits"] as? [[String: Any]] else { return nil }
            var added = 0, removed = 0, hunks: [DiffHunk] = [], tooLarge = false
            for edit in edits {
                guard let old = edit["old_string"] as? String, let new = edit["new_string"] as? String else { continue }
                let d = DiffEngine.fromEdit(old: old, new: new, path: path)
                added += d.added; removed += d.removed
                hunks += d.hunks
                tooLarge = tooLarge || d.tooLarge
            }
            return FileDiff(path: path, added: added, removed: removed, hunks: hunks, tooLarge: tooLarge, isNewFile: false)
        case "Write":
            guard let content = input["content"] as? String else { return nil }
            return DiffEngine.fromNew(content: content, path: path)
        default:
            return nil
        }
    }

    private func log(_ message: String) {
        CloudProbe.shared.log("[turn] \(message)")
    }
}
#endif
