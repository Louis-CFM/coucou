import Foundation

// MARK: - CursorCloudPoller
// Polls Cursor Cloud Agents API every 30s for recent agents.
// ACTIVE agents → working pill; transition out of ACTIVE → finished badge.

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

            let parsed = rawList.compactMap { self.parseAgent($0) }
                .filter { $0.status != "ARCHIVED" }
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

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
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
            state.tasks[idx].steps = [lead.name]
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
