import Foundation

final class ResendPoller: @unchecked Sendable {
    static let shared = ResendPoller()
    private var timer: DispatchSourceTimer?
    private init() {}

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        t.schedule(deadline: .now() + 6, repeating: 60)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    private func poll() {
        guard !DemoEngine.isPollerPaused else { return }
        guard let apiKey = KeychainStore.shared.get("resend-api-key") else { return }
        guard let url = URL(string: "https://api.resend.com/emails?limit=100") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            guard let self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, code == 200 else { return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawList = json["data"] as? [[String: Any]] else { return }

            let total = (json["total"] as? Int) ?? (json["count"] as? Int)
            let emails = rawList.compactMap { self.parseEmail($0) }

            DispatchQueue.main.async {
                AppState.shared.resendEmails = Array(emails.prefix(5))
                AppState.shared.resendTotal  = total ?? (emails.isEmpty ? nil : emails.count)
            }
        }.resume()
    }

    private func parseEmail(_ d: [String: Any]) -> ResendEmail? {
        guard let id        = d["id"]         as? String,
              let createdAt = d["created_at"] as? String else { return nil }

        let to: [String]
        if let arr = d["to"] as? [String] { to = arr }
        else if let single = d["to"] as? String { to = [single] }
        else { to = [] }

        let subject   = (d["subject"]    as? String) ?? ""
        let lastEvent = (d["last_event"] as? String) ?? ""

        // Parse ISO8601 date
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: createdAt)
                ?? ISO8601DateFormatter().date(from: createdAt)
                ?? Date()

        return ResendEmail(id: id, to: to, subject: subject, createdAt: date, lastEvent: lastEvent)
    }
}
