import Foundation
import SwiftUI

// MARK: - LinearPoller
// Polls the Linear GraphQL API every 60 s while the Linear pill is in the notch.
// A new unread inbox entry alerts on the pill; the first poll fills the list silently.

final class LinearPoller: @unchecked Sendable {
    static let shared = LinearPoller()
    private var timer: DispatchSourceTimer?
    // Accessed only on the main thread.
    private var seenIds: Set<String>?
    private init() {}

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        t.schedule(deadline: .now() + 11, repeating: 60, leeway: .seconds(10))
        t.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                guard AppState.shared.activeIntegrations.contains("integration_linear") else { return }
                self?.poll()
            }
        }
        t.resume()
        timer = t
    }

    func pollNow() { poll() }

    /// Forgets what the last key saw, so a new key starts silently.
    @MainActor func reset() {
        seenIds = nil
        let state = AppState.shared
        state.linearInbox = nil
        state.linearError = nil
    }

    private func poll() {
        guard !DemoEngine.isPollerPaused else { return }
        guard let key = KeychainStore.shared.get("linear-api-key"),
              let url = URL(string: LinearInbox.endpoint) else { return }

        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        // Personal API keys go in the header as-is, without "Bearer".
        req.setValue(key, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = LinearInbox.requestBody()

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let inbox = code == 200 ? data.flatMap { LinearInbox.parse($0) } : nil
            guard let inbox else {
                let msg: String
                if code == 401 { msg = "Invalid API key (401)" }
                else if code == 0 { msg = error?.localizedDescription ?? "No connection" }
                else if code == 200 { msg = "Unexpected response" }
                else { msg = "API error \(code)" }
                DispatchQueue.main.async { AppState.shared.setIfChanged(\.linearError, msg) }
                return
            }
            DispatchQueue.main.async { self.handle(inbox) }
        }.resume()
    }

    @MainActor
    private func handle(_ inbox: LinearInbox) {
        let state = AppState.shared
        state.setIfChanged(\.linearError, nil)
        let fresh = LinearInbox.fresh(inbox.unread, seen: seenIds)
        seenIds = Set(inbox.unread.map(\.id))
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            state.setIfChanged(\.linearInbox, inbox)
        }

        guard let newest = fresh.first,
              let idx = state.tasks.firstIndex(where: { $0.id == "integration_linear" }) else { return }
        let focused = state.focusId == "integration_linear"

        state.tasks[idx].state = .finished
        state.tasks[idx].steps = [[newest.key, newest.title].compactMap { $0 }.joined(separator: " ")]
        if !focused { state.tasks[idx].pillBadge = .finished }
        SoundEngine.shared.play("finish")
        NotificationCenter.default.post(name: .hookReveal, object: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            guard let i = state.tasks.firstIndex(where: { $0.id == "integration_linear" }) else { return }
            guard state.tasks[i].state == .finished else { return }
            state.tasks[i].state = .idle
            state.tasks[i].steps = []
            state.tasks[i].pillBadge = nil
        }
    }
}
