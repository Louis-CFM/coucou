import Foundation

// MARK: - N8nPoller
// Polls n8n for the latest workflow execution every 15s.
// Tries /api/v1/executions first, falls back to /rest/executions.
// On a new terminal execution: fetches full details, stores [name, detail] in steps.

final class N8nPoller: @unchecked Sendable {
    static let shared = N8nPoller()
    private var timer: DispatchSourceTimer?
    private var lastExecutionId: String = ""
    private var isFirstLoad: Bool = true

    // ISO8601DateFormatter is thread-safe; only read after creation.
    nonisolated(unsafe) private static let isoFormatterFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // ISO8601DateFormatter is thread-safe; only read after creation.
    nonisolated(unsafe) private static let isoFormatterStandard: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseExecutionDate(from json: [String: Any]) -> Date {
        let dateString = (json["stoppedAt"] as? String) ?? (json["startedAt"] as? String)
        if let dateString {
            if let date = isoFormatterFractional.date(from: dateString) ?? isoFormatterStandard.date(from: dateString) {
                return date
            }
        }
        return Date()
    }

    private init() {}

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        t.schedule(deadline: .now() + 3, repeating: 15, leeway: .seconds(3))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    // MARK: - Poll list endpoint

    private func poll() {
        guard !DemoEngine.isPollerPaused else { return }
        guard let apiKey  = KeychainStore.shared.get("n8n-api-key"),
              let rawBase = KeychainStore.shared.get("n8n-url") else {
            return   // not configured: nothing to do, nothing to log (this runs every 15 s)
        }
        let base = rawBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpoints = [
            "\(base)/api/v1/executions?limit=10&includeData=false",
            "\(base)/rest/executions?limit=10&includeData=false",
        ]
        tryList(endpoints, apiKey: apiKey, base: base, idx: 0)
    }

    private func tryList(_ urls: [String], apiKey: String, base: String, idx: Int) {
        guard idx < urls.count, let url = URL(string: urls[idx]) else {
            n8nLog("All list endpoints failed")
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(apiKey, forHTTPHeaderField: "X-N8N-API-KEY")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let error {
                self.n8nLog("Network error: \(error.localizedDescription)")
                self.tryList(urls, apiKey: apiKey, base: base, idx: idx + 1)
                return
            }
            guard let data else {
                self.tryList(urls, apiKey: apiKey, base: base, idx: idx + 1)
                return
            }
            // Only failures and changes are logged: a quiet poll writes nothing to disk.
            guard code == 200 else {
                self.n8nLog("HTTP \(code) · \(data.count) bytes")
                self.tryList(urls, apiKey: apiKey, base: base, idx: idx + 1)
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) else { return }

            // Response is either { "data": [...] } or [...]
            let items: [[String: Any]]
            if let obj = json as? [String: Any], let arr = obj["data"] as? [[String: Any]] {
                items = arr
            } else if let arr = json as? [[String: Any]] {
                items = arr
            } else {
                self.n8nLog("Unexpected response shape")
                return
            }

            let terminal = ["success", "error", "crashed", "canceled", "failed"]
            let terminalItems = items.filter { item in
                let status = item["status"] as? String ?? ""
                return terminal.contains(status)
            }

            guard let newest = terminalItems.first else {
                if self.isFirstLoad && items.isEmpty {
                    self.isFirstLoad = false
                }
                return
            }

            let newestId: String
            if let s = newest["id"] as? String      { newestId = s }
            else if let n = newest["id"] as? Int    { newestId = "\(n)" }
            else { self.n8nLog("No id in execution"); return }

            // First load — populate silently, anchor lastExecutionId to avoid duplicate on next poll
            if self.isFirstLoad {
                self.isFirstLoad = false
                self.lastExecutionId = newestId
                self.n8nLog("First load seeded lastExecutionId=\(newestId)")
                return
            }

            guard newestId != self.lastExecutionId else { return }

            // Identify all new terminal executions since lastExecutionId
            let newItems: [[String: Any]]
            if let idx = terminalItems.firstIndex(where: { item in
                let id = (item["id"] as? String) ?? (item["id"] as? Int).map(String.init) ?? ""
                return id == self.lastExecutionId
            }) {
                newItems = Array(terminalItems.prefix(upTo: idx))
            } else {
                newItems = terminalItems
            }

            guard let newestExec = newItems.first else { return }

            self.lastExecutionId = newestId
            let status = newestExec["status"] as? String ?? ""
            let success = status == "success"
            let newestDate = Self.parseExecutionDate(from: newestExec)
            self.n8nLog("New execution id=\(newestId) status=\(status)")

            // Process intermediate completed executions into history (oldest to newest)
            if newItems.count > 1 {
                let intermediate = Array(newItems.dropFirst().reversed())
                DispatchQueue.main.async {
                    let state = AppState.shared
                    for item in intermediate {
                        let name = self.extractWorkflowName(from: item)
                        let ok = (item["status"] as? String ?? "") == "success"
                        let date = Self.parseExecutionDate(from: item)
                        if state.n8nWorkflowFilter.isEmpty || state.n8nWorkflowFilter.contains(name) {
                            state.n8nRuns = Array(([N8nRun(workflow: name, detail: nil, success: ok, date: date)]
                                                   + state.n8nRuns).prefix(10))
                        }
                    }
                }
            }

            // Fetch full detail for the newest execution
            let detailUrls = [
                "\(base)/api/v1/executions/\(newestId)?includeData=true",
                "\(base)/api/v1/executions/\(newestId)",
                "\(base)/rest/executions/\(newestId)?includeData=true",
                "\(base)/rest/executions/\(newestId)",
            ]
            self.fetchDetail(detailUrls, apiKey: apiKey, success: success, fallbackDate: newestDate, idx: 0)
        }.resume()
    }

    // MARK: - Fetch full execution detail

    private func fetchDetail(_ urls: [String], apiKey: String, success: Bool, fallbackDate: Date, idx: Int) {
        guard idx < urls.count, let url = URL(string: urls[idx]) else {
            dispatch(success: success, name: "Workflow", detail: nil, date: fallbackDate)
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(apiKey, forHTTPHeaderField: "X-N8N-API-KEY")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            guard let self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, code == 200 else {
                self.n8nLog("Detail HTTP \(code) \(url.host ?? "?")\(url.path)")
                self.fetchDetail(urls, apiKey: apiKey, success: success, fallbackDate: fallbackDate, idx: idx + 1)
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.fetchDetail(urls, apiKey: apiKey, success: success, fallbackDate: fallbackDate, idx: idx + 1)
                return
            }
            let name = self.extractWorkflowName(from: json)
            let detail = self.parseDetail(from: json, success: success)
            let date = Self.parseExecutionDate(from: json)
            let executionDate = (json["stoppedAt"] != nil || json["startedAt"] != nil) ? date : fallbackDate
            self.n8nLog("Parsed: \(name)")
            self.dispatch(success: success, name: name, detail: detail, date: executionDate)
        }.resume()
    }

    private func extractWorkflowName(from json: [String: Any]) -> String {
        if let wd = json["workflowData"] as? [String: Any], let name = wd["name"] as? String { return name }
        if let name = json["name"] as? String { return name }
        return "Workflow"
    }

    // MARK: - Parse execution output / error message

    private func parseDetail(from json: [String: Any], success: Bool) -> String? {
        guard let execData   = json["data"] as? [String: Any],
              let resultData = execData["resultData"] as? [String: Any] else { return nil }

        if success {
            return parseSuccessDetail(resultData: resultData)
        } else {
            return parseErrorDetail(resultData: resultData)
        }
    }

    private func parseErrorDetail(resultData: [String: Any]) -> String? {
        // Top-level error
        if let error = resultData["error"] as? [String: Any] {
            let msg = error["message"] as? String ?? ""
            if let node = (error["node"] as? [String: Any])?["name"] as? String, !node.isEmpty {
                return "\(node)\n\(msg)"
            }
            return msg
        }
        // Scan runData for first node error
        if let runData = resultData["runData"] as? [String: Any] {
            for (nodeName, runs) in runData {
                if let runs = runs as? [[String: Any]],
                   let run = runs.first,
                   let err = run["error"] as? [String: Any],
                   let msg = err["message"] as? String {
                    return "\(nodeName)\n\(msg)"
                }
            }
        }
        return nil
    }

    private func parseSuccessDetail(resultData: [String: Any]) -> String? {
        guard let lastNode = resultData["lastNodeExecuted"] as? String,
              let runData  = resultData["runData"] as? [String: Any],
              let nodeRuns = runData[lastNode] as? [[String: Any]],
              let run      = nodeRuns.first,
              let data     = run["data"] as? [String: Any],
              let main     = data["main"] as? [[[String: Any]]],
              let items    = main.first else { return nil }

        let count = items.count
        let header = "→ \(lastNode) · \(count) item\(count == 1 ? "" : "s")"

        // Preview first item's JSON keys (up to 4)
        if let firstItem = items.first,
           let jsonObj = firstItem["json"] as? [String: Any], !jsonObj.isEmpty {
            let lines = jsonObj.prefix(4).map { "\($0.key): \(fmtValue($0.value))" }
            return "\(header)\n\(lines.joined(separator: "\n"))"
        }
        return header
    }

    private func fmtValue(_ v: Any) -> String {
        if let s = v as? String  { return String(s.prefix(50)) }
        if let n = v as? NSNumber { return n.stringValue }
        if let a = v as? [Any]   { return "[\(a.count)]" }
        if v is [String: Any]    { return "{…}" }
        return "\(v)"
    }

    // MARK: - Dispatch to main

    private func dispatch(success: Bool, name: String, detail: String?, date: Date) {
        DispatchQueue.main.async { self.handleExecution(success: success, name: name, detail: detail, date: date) }
    }

    @MainActor
    private func handleExecution(success: Bool, name: String, detail: String?, date: Date) {
        let state = AppState.shared

        // Apply workflow filter (empty = all workflows)
        if !state.n8nWorkflowFilter.isEmpty && !state.n8nWorkflowFilter.contains(name) { return }

        state.n8nRuns = Array(([N8nRun(workflow: name, detail: detail, success: success, date: date)]
                               + state.n8nRuns).prefix(10))

        guard let idx = state.tasks.firstIndex(where: { $0.id == "integration_n8n" }) else { return }
        let focused = state.focusId == "integration_n8n"

        state.tasks[idx].state = success ? .finished : .error
        state.tasks[idx].steps = detail != nil ? [name, detail!] : [name]

        if !focused {
            state.tasks[idx].pillBadge = success ? .finished : .error
        }
        SoundEngine.shared.play(success ? "finish" : "error")

        // Auto-clear after 60s (user needs time to read detail)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            guard let i = state.tasks.firstIndex(where: { $0.id == "integration_n8n" }) else { return }
            guard state.tasks[i].state == .finished || state.tasks[i].state == .error else { return }
            state.tasks[i].state    = .idle
            state.tasks[i].steps    = []
            state.tasks[i].pillBadge = nil
        }
    }

    // MARK: - Logging

    private func n8nLog(_ message: String) {
        appendAppLog("n8n.log", message, timestampFormat: "HH:mm:ss")
    }
}
