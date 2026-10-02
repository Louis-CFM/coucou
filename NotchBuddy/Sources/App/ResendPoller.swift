import Foundation

final class ResendPoller: @unchecked Sendable {
    static let shared = ResendPoller()
    private var timer: DispatchSourceTimer?
    private var knownEmailId = ""
    private var hasEmailBaseline = false
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
                Task { @MainActor in
                    let state = AppState.shared
                    state.resendEmails = Array(emails.prefix(5))
                    state.resendTotal  = total ?? (emails.isEmpty ? nil : emails.count)
                    guard let newest = emails.first else { return }
                    if !self.hasEmailBaseline {
                        self.hasEmailBaseline = true
                        self.knownEmailId = newest.id
                        return
                    }
                    guard newest.id != self.knownEmailId else { return }
                    self.knownEmailId = newest.id
                    state.presentNotice(
                        pillId: "integration_resend",
                        status: CoucouL10n.string("New email"),
                        headline: newest.subject.isEmpty ? newest.recipientShort : newest.subject,
                        detail: newest.recipientShort,
                        isFailure: newest.lastEvent == "bounced" || newest.lastEvent == "complained"
                    )
                }
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
