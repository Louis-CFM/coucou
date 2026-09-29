import Foundation

// MARK: - BibolPoller
// Polls the bibol feed on your VPS every 20s and shows new items as a notch pill.
//
// Settings (same as the chat backend):
//   UserDefaults "bibolURL"  = http://<vps>:8645/bibol/feed
//   Keychain     "bibol-key" = X-Bibol-Key token
//
// The bridge that serves this feed is `bibol_feed_server.py` on the VPS; alerts are
// appended by the scripts that run there (e.g. the Meteora degen watcher).

final class BibolPoller: @unchecked Sendable {
    static let shared = BibolPoller()
    private var timer: DispatchSourceTimer?
    private var lastItemId: String = ""

    private init() {}

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        t.schedule(deadline: .now() + 3, repeating: 20)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    private func poll() {
        let raw = (UserDefaults.standard.string(forKey: "bibolURL") ?? "")
            .replacingOccurrences(of: "/chat", with: "/bibol/feed")
        guard !raw.isEmpty, let url = URL(string: raw.trimmingCharacters(in: CharacterSet(charactersIn: " /"))) else {
            bibolLog("No bibolURL configured")
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        if let key = KeychainStore.shared.get("bibol-key"), !key.isEmpty {
            req.setValue(key, forHTTPHeaderField: "X-Bibol-Key")
        }
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let error {
                self.bibolLog("Network error: \(error.localizedDescription)")
                return
            }
            guard code == 200, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]],
                  let newest = items.first,
                  let itemId = newest["id"] as? String else {
                self.bibolLog("HTTP \(code) or unexpected shape")
                return
            }
            guard itemId != self.lastItemId else { return }   // nothing new
            self.lastItemId = itemId

            let title  = newest["title"] as? String ?? "bibol"
            let detail = newest["detail"] as? String
            DispatchQueue.main.async {
                self.handleAlert(title: title, detail: detail)
            }
        }.resume()
    }

    @MainActor
    private func handleAlert(title: String, detail: String?) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == "integration_bibol" }) else { return }
        let focused = state.focusId == "integration_bibol"

        state.tasks[idx].state = .finished
        state.tasks[idx].steps = detail != nil ? [title, detail!] : [title]
        if !focused {
            state.tasks[idx].pillBadge = .finished
        }
        SoundEngine.shared.play("finish")

        // Auto-clear after 60s so the detail stays readable, mirroring the other pollers.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            guard let i = state.tasks.firstIndex(where: { $0.id == "integration_bibol" }) else { return }
            guard state.tasks[i].state == .finished else { return }
            state.tasks[i].state     = .idle
            state.tasks[i].steps     = []
            state.tasks[i].pillBadge = nil
        }
    }

    // MARK: - Logging

    private func bibolLog(_ message: String) {
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/NotchBuddy")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let logFile = logsDir.appendingPathComponent("bibol.log")
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        let line = "\(f.string(from: Date())) · \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logFile.path) {
            if let fh = try? FileHandle(forWritingTo: logFile) {
                fh.seekToEndOfFile(); fh.write(data); try? fh.close()
            }
        } else { try? data.write(to: logFile) }
    }
}
