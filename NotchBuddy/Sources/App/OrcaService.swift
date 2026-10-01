import Foundation
import Darwin
import AppKit

// MARK: - OrcaService
//
// Consumes a running Orca instance (the coding-agent orchestrator) through its local
// runtime socket — the same JSON-RPC endpoint the `orca` CLI uses. Connection metadata
// comes from <Application Support>/orca/orca-runtime.json (transports[] + authToken).
//
// Every 5 s it calls `worktree.ps` and maps each worktree's status to a normalized
// AgentEvent through the shared AgentEventRouter:
//   permission → approval alert (sound + pinned card + pill badge)
//   done       → finished      working → working
// The ticker shows one line per active worktree.
//
// Approval is answered inside Orca (MVP): the card offers "Open Orca" instead of
// Allow/Deny — remote approval of terminal agents needs Orca's session-reply RPC and
// is not wired yet. Dismissing the card only hides it here; the agent stays blocked.

/// One `worktree.ps` row, flattened and Sendable so it can cross isolation boundaries.
struct OrcaWorktreeRow: Sendable {
    let id: String
    let repo: String
    let displayName: String
    let path: String
    let status: String      // active | working | permission | done | inactive
    let agentType: String   // claude, codex, …
    let prompt: String      // what the user asked (shown in the approval card)
}

final class OrcaService: @unchecked Sendable {
    static let shared = OrcaService()

    /// Prefix marking an ApprovalInfo.sessionId as owned by Orca (see ApprovalView).
    static let approvalPrefix = "orca:"

    // MARK: - AgentService state
    // (conformance declared in the extension below — declaring it on the class would
    // make Swift isolate the whole type to the main actor; socket I/O runs on threads)

    let taskID = "integration_orca"
    let source: AgentSource = .orca

    /// Only while the card on screen is Orca's — a Claude Code card shown on top must keep
    /// routing its Allow/Deny to HookServer.
    @MainActor
    var hasPendingApproval: Bool { !pendingApprovals.isEmpty && isOrcaCardShown }

    private var timer: DispatchSourceTimer?

    // Main-actor state (mutated only from @MainActor methods)
    private var statusById: [String: String] = [:]  // worktreeId → last seen status
    private var pendingApprovals: Set<String> = []  // fired approvals not yet resolved
    private var deferredApprovals: Set<String> = [] // waiting for another provider's card to close
    private var firstPoll = true                    // baseline poll: only alerts, no "finished"
    private var missCount = 0                       // consecutive unreachable polls
    private var lastPath = ""                       // runtime JSON last probed (for logs)

    private init() {}

    // MARK: - Start

    @MainActor
    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 6, repeating: 5)
        // The timer fires on a background queue. The closure must not inherit start()'s
        // MainActor isolation — explicit @Sendable typing breaks the inheritance.
        let handler: @Sendable () -> Void = { [weak self] in self?.tick() }
        t.setEventHandler(handler: handler)
        t.resume()
        timer = t
        agentLog("OrcaService: polling worktree.ps every 5 s")
    }

    // MARK: - Poll

    // nonisolated: the timer closure inherits start()'s MainActor isolation but runs on a
    // background queue — a @MainActor tick() would trip the runtime's queue assertion.
    // Mirrors the pollers: DispatchQueue.main.async for main-actor hops, never Task {}.
    private nonisolated func tick() {
        DispatchQueue.main.async {
            let state = AppState.shared
            guard state.tasks.contains(where: { $0.id == self.taskID }) else { return }
            let path = state.orcaRuntimeFilePath
            self.lastPath = path
            Thread.detachNewThread {
                let rows = Self.queryWorktrees(runtimePath: path)
                DispatchQueue.main.async { self.consume(rows) }
            }
        }
    }

    /// One `worktree.ps` call over Orca's local runtime socket (newline-delimited JSON,
    /// authenticated with the authToken from orca-runtime.json). Returns nil when the
    /// runtime is unreachable — Orca not running, stale socket file, bad token, timeout.
    nonisolated static func queryWorktrees(runtimePath: String) -> [OrcaWorktreeRow]? {
        guard let data = FileManager.default.contents(atPath: runtimePath),
              let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = meta["authToken"] as? String,
              let transports = meta["transports"] as? [[String: Any]],
              let endpoint = transports.first(where: { $0["kind"] as? String == "unix" })?["endpoint"] as? String
        else { return nil }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cpath = Array(endpoint.utf8CString)
        guard cpath.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, c) in cpath.enumerated() where i < raw.count { raw[i] = UInt8(bitPattern: c) }
        }

        // Bounded I/O so a hung runtime never stalls the poll loop
        var tv = timeval(tv_sec: 4, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { return nil }

        let request: [String: Any] = [
            "id": "coucou-\(UUID().uuidString)",
            "authToken": token,
            "method": "worktree.ps",
            "params": ["limit": 50]
        ]
        guard var payload = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        payload.append(UInt8(ascii: "\n"))
        let sent = payload.withUnsafeBytes { buf in Darwin.write(fd, buf.baseAddress, buf.count) }
        guard sent == payload.count else { return nil }

        var raw = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        outer: while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            raw.append(contentsOf: buf[0..<n])
            if raw.contains(UInt8(ascii: "\n")) { break outer }
            if raw.count > 4_000_000 { break }
        }
        guard let lineEnd = raw.firstIndex(of: UInt8(ascii: "\n")),
              let json = try? JSONSerialization.jsonObject(with: raw[0..<lineEnd]) as? [String: Any],
              json["ok"] as? Bool == true,
              let result = json["result"] as? [String: Any],
              let worktrees = result["worktrees"] as? [[String: Any]]
        else { return nil }

        return worktrees.compactMap { w in
            guard let id = w["worktreeId"] as? String, let status = w["status"] as? String else { return nil }
            let agents = w["agents"] as? [[String: Any]] ?? []
            let interesting = ["blocked", "waiting", "working"]
            let agent = agents.first { interesting.contains($0["state"] as? String ?? "") } ?? agents.first
            let prompt = (agent?["prompt"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (agent?["taskTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? ""
            return OrcaWorktreeRow(
                id: id,
                repo: w["repo"] as? String ?? "",
                displayName: w["displayName"] as? String ?? "",
                path: w["path"] as? String ?? "",
                status: status,
                agentType: agent?["agentType"] as? String ?? "",
                prompt: prompt
            )
        }
    }

    // MARK: - Consume (main actor)

    @MainActor
    private func consume(_ rows: [OrcaWorktreeRow]?) {
        // Runtime unreachable: keep the last known state, but release an Orca approval
        // card only after 3 consecutive misses (~15 s) so a single slow poll can't clear it.
        guard let rows else {
            missCount += 1
            if missCount == 1 { agentLog("OrcaService: runtime unreachable at \(lastPath)") }
            if missCount >= 3, pendingApprovals.isEmpty == false {
                pendingApprovals.removeAll()
                if isOrcaCardShown {
                    AgentEventRouter.shared.handle(AgentEvent(taskID: taskID, kind: .permissionResolved(.allow)))
                }
            }
            return
        }
        missCount = 0

        // Another provider (Claude Code) took over the approval card: park ours until it closes.
        if !pendingApprovals.isEmpty, isForeignCardShown {
            deferredApprovals.formUnion(pendingApprovals)
            pendingApprovals.removeAll()
        }

        let previous = statusById
        let isFirst = firstPoll
        firstPoll = false
        if isFirst { agentLog("OrcaService: baseline — \(rows.count) worktree(s) visible") }

        var next: [String: String] = [:]
        var stillPending: Set<String> = []
        var enteredPermission: [OrcaWorktreeRow] = []
        var enteredDone: [OrcaWorktreeRow] = []
        var enteredWorking = false

        for row in rows {
            next[row.id] = row.status
            let old = previous[row.id]
            if row.status == "permission" {
                stillPending.insert(row.id)
                if old != "permission" { enteredPermission.append(row) }
            }
            if !isFirst {
                if row.status == "done", old != "done" { enteredDone.append(row) }
                if row.status == "working", old != "working" { enteredWorking = true }
            }
        }
        statusById = next

        // 1. New approvals → alert (also on the first poll: an approval already waiting
        //    at launch is exactly what the user wants to hear about).
        for row in enteredPermission {
            fireApproval(row)
        }

        // 2. Approvals answered inside Orca → release the card once none remain.
        let left = pendingApprovals.subtracting(stillPending)
        pendingApprovals.formIntersection(stillPending)
        if !left.isEmpty {
            if pendingApprovals.isEmpty {
                if isOrcaCardShown {
                    pendingApprovals.removeAll()
                    AgentEventRouter.shared.handle(AgentEvent(taskID: taskID, kind: .permissionResolved(.allow)))
                }
            } else if isOrcaCardShown, let still = rows.first(where: { stillPending.contains($0.id) }) {
                // The row shown in the card resolved, but another one still waits: repoint.
                fireApproval(still)
            }
        }

        // 2b. Parked approvals still waiting in Orca → show them once the card is free.
        deferredApprovals.formIntersection(stillPending)
        if !deferredApprovals.isEmpty, AppState.shared.pendingApproval == nil {
            for row in rows where deferredApprovals.contains(row.id) {
                fireApproval(row)
            }
        }

        // 3. Completions / activity — skipped on the baseline poll to avoid an alert storm.
        if !enteredDone.isEmpty {
            for row in enteredDone {
                AgentEventRouter.shared.handle(AgentEvent(
                    taskID: taskID,
                    projectName: projectName(for: row),
                    cwd: row.path,
                    kind: .finished(row.displayName.isEmpty ? row.repo : row.displayName)
                ))
            }
        } else if enteredWorking && stillPending.isEmpty {
            AgentEventRouter.shared.handle(AgentEvent(taskID: taskID, kind: .working))
        }

        updateSteps(rows)
    }

    /// Never replaces another provider's approval card: a Claude Code request blocks the
    /// agent until answered, so hiding it would leave the user without the buttons.
    @MainActor
    private func fireApproval(_ row: OrcaWorktreeRow) {
        guard !isForeignCardShown else {
            deferredApprovals.insert(row.id)
            return
        }
        deferredApprovals.remove(row.id)
        pendingApprovals.insert(row.id)
        AgentEventRouter.shared.handle(AgentEvent(
            taskID: taskID,
            projectName: projectName(for: row),
            cwd: row.path,
            kind: .permissionRequest(AgentPermissionRequest(
                sessionID: Self.approvalPrefix + row.id,
                requestID: "",                       // Orca has no per-request correlation id here
                tool: row.agentType.isEmpty ? "Orca agent" : "\(row.agentType) (Orca)",
                command: row.prompt.isEmpty ? row.displayName : String(row.prompt.prefix(200))
            ))
        ))
    }

    /// True when the approval card currently displayed belongs to Orca.
    @MainActor
    private var isOrcaCardShown: Bool {
        AppState.shared.pendingApproval?.sessionId.hasPrefix(Self.approvalPrefix) == true
    }

    /// True when the approval card currently displayed belongs to another provider.
    @MainActor
    private var isForeignCardShown: Bool {
        AppState.shared.pendingApproval != nil && !isOrcaCardShown
    }

    private func projectName(for row: OrcaWorktreeRow) -> String {
        row.repo.isEmpty ? row.displayName : row.repo
    }

    /// One ticker line per active worktree: "tradespace · sprint/s05 · working".
    @MainActor
    private func updateSteps(_ rows: [OrcaWorktreeRow]) {
        let words: [String: String] = ["permission": "approval needed", "working": "working", "done": "done"]
        var steps: [String] = []
        for row in rows {
            guard let word = words[row.status] else { continue }
            var label = row.repo.isEmpty ? row.displayName : row.repo
            if !row.displayName.isEmpty, row.displayName != row.repo {
                label += " · \(row.displayName)"
            }
            steps.append(row.status == "permission" ? "⚠ \(label) · \(word)" : "\(label) · \(word)")
            if steps.count == 6 { break }
        }
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == taskID }) else { return }
        if state.tasks[idx].steps != steps {
            state.tasks[idx].steps = steps
            state.tasks[idx].stepIndex = max(steps.count - 1, 0)
        }
    }

    // MARK: - Actions

    /// Launches (or activates) Orca.app — used by the "Open Orca" button on the card.
    @MainActor
    static func openOrca() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.stablyai.orca") {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Orca.app"))
        }
    }
}

// MARK: - AgentService (declared in an extension, mirroring HookServer)

extension OrcaService: AgentService {
    /// Approval card button ("Dismiss"): hides the card here only — the agent keeps
    /// waiting until answered inside Orca. Never a silent allow/deny.
    @MainActor
    func respond(to decision: AgentApprovalDecision) {
        agentLog("OrcaService: card dismissed (\(decision)) — approval still pending in Orca")
        pendingApprovals.removeAll()
        deferredApprovals.removeAll()
        AgentEventRouter.shared.handle(AgentEvent(taskID: taskID, kind: .permissionResolved(decision)))
    }
}
