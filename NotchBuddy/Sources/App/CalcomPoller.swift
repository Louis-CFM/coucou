import Foundation

final class CalcomPoller: @unchecked Sendable {
    static let shared = CalcomPoller()
    private var timer: DispatchSourceTimer?
    private init() {}

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        t.schedule(deadline: .now() + 8, repeating: 300, leeway: .seconds(30))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func pollNow() { poll() }

    private func poll() {
        guard !DemoEngine.isPollerPaused else { return }
        guard let key = KeychainStore.shared.get("calcom-api-key") else { return }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let future = cal.date(byAdding: .day, value: 60, to: today)!
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
        let startStr = iso.string(from: today)
        let endStr   = iso.string(from: future)

        // API v2 (2024-08-13) filters on afterStart / beforeEnd; `start` and `end` aren't
        // query parameters there, so they returned nothing.
        var components = URLComponents(string: "https://api.cal.com/v2/bookings")!
        components.queryItems = [URLQueryItem(name: "status", value: "upcoming"),
                                 URLQueryItem(name: "afterStart", value: startStr),
                                 URLQueryItem(name: "beforeEnd", value: endStr),
                                 URLQueryItem(name: "take", value: "50")]
        guard let url = components.url else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("2024-08-13", forHTTPHeaderField: "cal-api-version")

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code != 200 {
                let msg: String
                if code == 401 { msg = "Invalid API key (401)" }
                else if code == 0 { msg = error?.localizedDescription ?? "No connection" }
                else { msg = "API error \(code)" }
                DispatchQueue.main.async { AppState.shared.setIfChanged(\.calcomError, msg) }
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawList = json["data"] as? [[String: Any]] else { return }

            let parsed = rawList.compactMap { self.parseBooking($0) }
            DispatchQueue.main.async {
                AppState.shared.setIfChanged(\.calcomError, nil)
                AppState.shared.setIfChanged(\.calcomBookings, parsed)
                AppState.shared.setIfChanged(\.calcomLoaded, true)
            }
        }.resume()
    }

    private func parseBooking(_ b: [String: Any]) -> CalcomBooking? {
        let id: Int
        if let i = b["id"] as? Int { id = i }
        else if let s = b["id"] as? String, let i = Int(s) { id = i }
        else { return nil }

        let title  = (b["title"] as? String) ?? "Meeting"
        let status = (b["status"] as? String) ?? "accepted"
        guard let startStr = (b["start"] as? String) ?? (b["startTime"] as? String) else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var startTime = iso.date(from: startStr)
        if startTime == nil {
            let iso2 = ISO8601DateFormatter(); iso2.formatOptions = [.withInternetDateTime]
            startTime = iso2.date(from: startStr)
        }
        guard let startTime else { return nil }

        let endStr = (b["end"] as? String) ?? (b["endTime"] as? String) ?? ""
        let endTime: Date = iso.date(from: endStr) ?? startTime

        let attendees = b["attendees"] as? [[String: Any]] ?? []
        let first = attendees.first
        let name  = first?["name"]  as? String
        let email = first?["email"] as? String

        var notes: String? = nil
        if let responses = b["responses"] as? [String: Any],
           let notesObj  = responses["notes"] as? [String: Any] {
            notes = notesObj["value"] as? String
        }
        if (notes == nil || notes!.isEmpty), let desc = b["description"] as? String, !desc.isEmpty {
            notes = desc
        }

        return CalcomBooking(id: id, title: title, startTime: startTime, endTime: endTime,
                             status: status, attendeeName: name, attendeeEmail: email,
                             attendeeNotes: notes)
    }
}
