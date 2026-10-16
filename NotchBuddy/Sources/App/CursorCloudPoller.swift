import AppKit
import Foundation

// MARK: - CursorCloudPoller
// Polls Cursor Cloud Agents API every 30s for recent agents.
// ACTIVE agents → working pill; transition out of ACTIVE → finished badge.
// For up to 2 ACTIVE agents, also fetches Get A Run for a short “what it's doing” label.

final class CursorCloudPoller: @unchecked Sendable {
    static let shared = CursorCloudPoller()
    private var timer: DispatchSourceTimer?
    /// Fingerprint of active agent ids from the previous successful poll.
    private var lastActiveFingerprint: String? = nil
    private var hasLoadedOnce = false

    private init() {}

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        t.schedule(deadline: .now() + 7, repeating: 30)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func pollNow() { poll() }

    private func poll() {
        guard !DemoEngine.isPollerPaused else { return }
        guard let key = KeychainStore.shared.get("cursor-api-key") else { return }

        guard let url = URL(string: "https://api.cursor.com/v1/agents?limit=20") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        let creds = Data("\(key):".utf8).base64EncodedString()
        req.setValue("Basic \(creds)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code != 200 {
                let errMsg: String
                if code == 401 { errMsg = "Invalid API key (401)" }
                else if code == 403 { errMsg = "Key lacks access (403)" }
                else if code == 0   { errMsg = error?.localizedDescription ?? "No connection" }
                else                { errMsg = "API error \(code)" }
                DispatchQueue.main.async { AppState.shared.cursorCloudError = errMsg }
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawList = json["items"] as? [[String: Any]] else { return }

            var parsed = rawList.compactMap { self.parseAgent($0) }
                .filter { $0.status != "ARCHIVED" }
            parsed = self.enrichActiveRuns(agents: parsed, key: key)
            DispatchQueue.main.async { self.handleAgents(parsed) }
        }.resume()
    }

    private func parseAgent(_ a: [String: Any]) -> CursorCloudAgent? {
        guard let id = a["id"] as? String,
              let name = a["name"] as? String,
              let status = a["status"] as? String else { return nil }
        let url = (a["url"] as? String) ?? "https://cursor.com/agents/\(id)"
        let latestRunId = a["latestRunId"] as? String
        let updatedAt = Self.parseDate(a["updatedAt"] as? String) ?? Date()
        return CursorCloudAgent(id: id, name: name, status: status, url: url,
                                latestRunId: latestRunId, updatedAt: updatedAt)
    }

    /// Fetches Get A Run for up to 2 ACTIVE agents (rate-limit friendly).
    private func enrichActiveRuns(agents: [CursorCloudAgent], key: String) -> [CursorCloudAgent] {
        var result = agents
        let targets = result.indices.filter { result[$0].isActive && result[$0].latestRunId != nil }.prefix(2)
        guard !targets.isEmpty else { return result }

        let group = DispatchGroup()
        let lock = NSLock()
        for i in targets {
            guard let runId = result[i].latestRunId else { continue }
            let agentId = result[i].id
            group.enter()
            fetchRun(agentId: agentId, runId: runId, key: key) { status, resultText in
                lock.lock()
                if let status {
                    result[i].runStatus = status
                    result[i].detail = Self.detailLabel(runStatus: status, result: resultText)
                }
                lock.unlock()
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + 10)
        return result
    }

    private func fetchRun(agentId: String, runId: String, key: String,
                          done: @escaping (String?, String?) -> Void) {
        guard let url = URL(string: "https://api.cursor.com/v1/agents/\(agentId)/runs/\(runId)") else {
            done(nil, nil)
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 8)
        let creds = Data("\(key):".utf8).base64EncodedString()
        req.setValue("Basic \(creds)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                done(nil, nil)
                return
            }
            let status = json["status"] as? String
            let result = json["result"] as? String
            done(status, result)
        }.resume()
    }

    private static func detailLabel(runStatus: String, result: String?) -> String {
        let pretty = CursorCloudAgent.prettyRunStatus(runStatus)
        // Terminal runs may include a short final reply — keep it tiny for the row.
        if let result, !result.isEmpty,
           runStatus.uppercased() == "FINISHED" || runStatus.uppercased() == "ERROR" {
            let one = result
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                ?? pretty
            let trimmed = one.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count > 28 {
                return String(trimmed.prefix(27)) + "…"
            }
            return trimmed.isEmpty ? pretty : trimmed
        }
        return pretty
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    /// Prefer Cursor Desktop deeplink; fall back to the web agent URL.
    static func openAgent(_ agent: CursorCloudAgent) {
        if let app = URL(string: agent.appURL), NSWorkspace.shared.open(app) { return }
        if let web = URL(string: agent.url) { NSWorkspace.shared.open(web) }
    }

    @MainActor
    private func handleAgents(_ agents: [CursorCloudAgent]) {
        let state = AppState.shared
        state.cursorCloudError = nil
        state.cursorCloudAgents = agents
        state.cursorCloudLoaded = true

        let active = agents.filter(\.isActive)
        let fingerprint = active.map(\.id).sorted().joined(separator: ",")

        guard let idx = state.tasks.firstIndex(where: { $0.id == "integration_cursor_cloud" }) else {
            lastActiveFingerprint = fingerprint
            hasLoadedOnce = true
            return
        }
        let focused = state.focusId == "integration_cursor_cloud"

        if !active.isEmpty {
            let lead = active[0]
            state.tasks[idx].state = .working
            if let detail = lead.detail, !detail.isEmpty {
                state.tasks[idx].steps = ["\(lead.name) · \(detail)"]
            } else {
                state.tasks[idx].steps = [lead.name]
            }
            let becameActive = hasLoadedOnce && fingerprint != lastActiveFingerprint
                && !fingerprint.isEmpty
            if becameActive {
                // No PillBadge for working — only approval / finished / error exist.
                SoundEngine.shared.play("work")
                NotificationCenter.default.post(name: .hookReveal, object: nil)
            }
        } else if hasLoadedOnce, let prev = lastActiveFingerprint, !prev.isEmpty {
            // Had ACTIVE agents last time; now none.
            state.tasks[idx].state = .finished
            state.tasks[idx].steps = agents.first.map { [$0.name] } ?? ["Done"]
            if !focused { state.tasks[idx].pillBadge = .finished }
            SoundEngine.shared.play("finish")
            NotificationCenter.default.post(name: .hookReveal, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                guard let i = state.tasks.firstIndex(where: { $0.id == "integration_cursor_cloud" }) else { return }
                guard state.tasks[i].state == .finished else { return }
                state.tasks[i].state = .idle
                state.tasks[i].steps = []
                state.tasks[i].pillBadge = nil
            }
        } else if state.tasks[idx].state == .working {
            // Still loading or idle list — clear stale working if API says idle.
            state.tasks[idx].state = .idle
            state.tasks[idx].steps = []
            state.tasks[idx].pillBadge = nil
        }

        lastActiveFingerprint = fingerprint
        hasLoadedOnce = true
    }
}
