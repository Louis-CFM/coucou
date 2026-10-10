import Foundation

final class NotionPoller: @unchecked Sendable {
    static let shared = NotionPoller()
    private var timer: DispatchSourceTimer?
    private init() {}

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        t.schedule(deadline: .now() + 9, repeating: 300, leeway: .seconds(30))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func pollNow() { poll() }

    private func poll() {
        guard !DemoEngine.isPollerPaused else { return }
        guard let token = KeychainStore.shared.get("notion-api-key") else { return }
        guard let url = URL(string: "https://api.notion.com/v1/search") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "sort": ["direction": "descending", "timestamp": "last_edited_time"],
            "page_size": 3
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code != 200 {
                let msg: String
                if code == 401 { msg = "Invalid API key (401)" }
                else if code == 0 { msg = error?.localizedDescription ?? "No connection" }
                else { msg = "API error \(code)" }
                DispatchQueue.main.async { AppState.shared.setIfChanged(\.notionError, msg) }
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else { return }

            let pages = results.compactMap { self.parsePage($0) }
            DispatchQueue.main.async {
                AppState.shared.setIfChanged(\.notionError, nil)
                AppState.shared.notionPages = pages
                AppState.shared.setIfChanged(\.notionLoaded, true)
            }
        }.resume()
    }

    private func parsePage(_ obj: [String: Any]) -> NotionPage? {
        guard let id = obj["id"] as? String else { return nil }
        let objType = obj["object"] as? String ?? "page"

        var title = "Untitled"
        if objType == "database" {
            if let arr = obj["title"] as? [[String: Any]],
               let text = arr.first?["plain_text"] as? String, !text.isEmpty {
                title = text
            }
        } else {
            if let props = obj["properties"] as? [String: Any] {
                for (_, val) in props {
                    guard let prop = val as? [String: Any],
                          (prop["type"] as? String) == "title",
                          let arr = prop["title"] as? [[String: Any]],
                          let text = arr.first?["plain_text"] as? String, !text.isEmpty else { continue }
                    title = text; break
                }
            }
        }

        var emoji: String? = nil
        if let icon = obj["icon"] as? [String: Any],
           (icon["type"] as? String) == "emoji",
           let em = icon["emoji"] as? String {
            emoji = em
        }

        guard let editedStr = obj["last_edited_time"] as? String else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lastEdited = iso.date(from: editedStr)
        if lastEdited == nil {
            let iso2 = ISO8601DateFormatter(); iso2.formatOptions = [.withInternetDateTime]
            lastEdited = iso2.date(from: editedStr)
        }
        guard let lastEdited else { return nil }

        let pageURL = (obj["url"] as? String) ?? "https://notion.so"
        return NotionPage(id: id, title: title, emoji: emoji, lastEditedAt: lastEdited, url: pageURL)
    }
}
