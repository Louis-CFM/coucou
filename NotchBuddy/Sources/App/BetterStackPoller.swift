import Foundation

// MARK: - BetterStackPoller
// Polls the Better Stack Uptime API every 60 s while the pill is declared:
// open incidents and monitors that are down. A new incident turns the pill to
// error; the last one resolving turns it to finished.

final class BetterStackPoller: @unchecked Sendable {
    static let shared = BetterStackPoller()
    static let pillId = "integration_betterstack"
    private var timer: DispatchSourceTimer?
    /// Open incidents seen on the last poll (id → name); nil until the first one.
    private var seen: [String: String]?

    private init() {}

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        t.schedule(deadline: .now() + 10, repeating: 60, leeway: .seconds(10))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func pollNow() { poll() }

    /// A new token is a new account: forget its incidents, and alert on none of them.
    @MainActor func reset() {
        seen = nil
        let s = AppState.shared
        s.betterstackIncidents = []
        s.betterstackDownMonitors = []
        s.betterstackLoaded = false
        s.betterstackError = nil
    }

    @MainActor private static var isWanted: Bool {
        AppState.shared.activeIntegrations.contains(pillId)
    }

    // MARK: - Poll

    private func poll() {
        guard !DemoEngine.isPollerPaused else { return }
        guard let token = KeychainStore.shared.get("betterstack-token") else { return }
        Task { @MainActor in
            guard Self.isWanted else { return }
            async let incidents = Self.fetch(BetterStackAPI.incidentsURL, token: token)
            async let monitors  = Self.fetch(BetterStackAPI.monitorsURL, token: token)
            let (i, m) = await (incidents, monitors)
            self.handle(incidents: i, monitors: m)
        }
    }

    private enum Fetch {
        case ok(Data)
        case failed(String)
    }

    private static func fetch(_ url: URL, token: String) async -> Fetch {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 { return .ok(data) }
            if code == 401 || code == 403 { return .failed("Invalid token (\(code))") }
            return .failed("API error \(code)")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    @MainActor
    private func handle(incidents: Fetch, monitors: Fetch) {
        let s = AppState.shared
        guard case .ok(let incidentData) = incidents,
              let open = BetterStackAPI.incidents(from: incidentData) else {
            if case .failed(let msg) = incidents { s.setIfChanged(\.betterstackError, msg) }
            return
        }
        // Monitors are extra: a failed call keeps the last list.
        if case .ok(let monitorData) = monitors, let down = BetterStackAPI.downMonitors(from: monitorData) {
            s.setIfChanged(\.betterstackDownMonitors, down)
        }
        s.setIfChanged(\.betterstackError, nil)
        s.setIfChanged(\.betterstackIncidents, open)
        s.setIfChanged(\.betterstackLoaded, true)

        let change = BetterStackAPI.change(previous: seen, current: open)
        seen = Dictionary(open.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })

        switch change {
        case .none:
            return
        case .opened(let incident):
            flag(error: true, label: incident.name, detail: incident.cause)
        case .resolved(let name):
            // Only all-clear is good news; one of two incidents resolving isn't.
            guard open.isEmpty else { return }
            flag(error: false, label: name, detail: String(localized: "Resolved"))
        }
    }

    /// Same reveal, badge, sound and 60 s auto-clear as the other pollers.
    @MainActor
    private func flag(error: Bool, label: String, detail: String?) {
        let s = AppState.shared
        let id = Self.pillId
        guard let idx = s.tasks.firstIndex(where: { $0.id == id }) else { return }
        s.tasks[idx].state = error ? .error : .finished
        s.tasks[idx].steps = [label, detail].compactMap { $0 }
        s.tasks[idx].stepIndex = s.tasks[idx].steps.count - 1
        if s.focusId != id { s.tasks[idx].pillBadge = error ? .error : .finished }
        SoundEngine.shared.play(error ? "error" : "finish")
        NotificationCenter.default.post(name: .hookReveal, object: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            guard let i = s.tasks.firstIndex(where: { $0.id == id }) else { return }
            guard s.tasks[i].state == .finished || s.tasks[i].state == .error else { return }
            s.tasks[i].state = .idle
            s.tasks[i].steps = []
            s.tasks[i].pillBadge = nil
        }
    }
}
