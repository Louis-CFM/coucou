import Foundation

// MARK: - N8nPoller
// Polls n8n for the latest workflow execution every 15s.
// Tries /api/v1/executions first, falls back to /rest/executions.
// On a new terminal execution: fetches full details, stores [name, detail] in steps.

final class N8nPoller: @unchecked Sendable {
    static let shared = N8nPoller()
    private var timer: DispatchSourceTimer?
    private var lastExecutionId: String = ""
    private var didBaselineNotice = false

    private init() {}

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        t.schedule(deadline: .now() + 3, repeating: 15)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    // MARK: - Poll list endpoint

    private func poll() {
        guard let apiKey  = KeychainStore.shared.get("n8n-api-key"),
              let rawBase = KeychainStore.shared.get("n8n-url") else {
            n8nLog("No API key or URL configured")
            return
        }
        let base = rawBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpoints = [
            "\(base)/api/v1/executions?limit=1&includeData=false",
            "\(base)/rest/executions?limit=1&includeData=false",
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
        n8nLog("Polling \(url.host ?? "?")\(url.path)")

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
            self.n8nLog("HTTP \(code) · \(data.count) bytes")
            guard code == 200 else {
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

            guard let first = items.first else { self.n8nLog("No executions found"); return }

            let id: String
            if let s = first["id"] as? String      { id = s }
            else if let n = first["id"] as? Int    { id = "\(n)" }
            else { self.n8nLog("No id in execution"); return }

            guard id != self.lastExecutionId else {
                self.n8nLog("Same id=\(id) — no change")
                return
            }

            // Terminal check: use status field — more reliable than the `finished` bool
            // (published workflows often have finished=false on error)
            let status = first["status"] as? String ?? ""
            let isTerminal = ["success", "error", "crashed", "canceled", "failed"].contains(status)
            guard isTerminal else {
                self.n8nLog("id=\(id) status=\(status.isEmpty ? "?" : status) — not terminal")
                return
            }

            self.lastExecutionId = id
            let success = status == "success"
            self.n8nLog("New execution id=\(id) status=\(status)")

            // Fetch full detail (includeData=true required in some n8n versions)
            let detailUrls = [
                "\(base)/api/v1/executions/\(id)?includeData=true",
                "\(base)/api/v1/executions/\(id)",
                "\(base)/rest/executions/\(id)?includeData=true",
                "\(base)/rest/executions/\(id)",
            ]
            self.fetchDetail(detailUrls, apiKey: apiKey, success: success, idx: 0)
        }.resume()
    }

    // MARK: - Fetch full execution detail

    private func fetchDetail(_ urls: [String], apiKey: String, success: Bool, idx: Int) {
        guard idx < urls.count, let url = URL(string: urls[idx]) else {
            dispatch(success: success, name: "Workflow", detail: nil)
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
                self.fetchDetail(urls, apiKey: apiKey, success: success, idx: idx + 1)
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.fetchDetail(urls, apiKey: apiKey, success: success, idx: idx + 1)
                return
            }
            let name = self.extractWorkflowName(from: json)
            let detail = self.parseDetail(from: json, success: success)
            self.n8nLog("Parsed: \(name)")
            self.dispatch(success: success, name: name, detail: detail)
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

    private func dispatch(success: Bool, name: String, detail: String?) {
        DispatchQueue.main.async { self.handleExecution(success: success, name: name, detail: detail) }
    }

    @MainActor
    private func handleExecution(success: Bool, name: String, detail: String?) {
        let state = AppState.shared

        // Apply workflow filter (empty = all workflows)
        if !state.n8nWorkflowFilter.isEmpty && !state.n8nWorkflowFilter.contains(name) { return }

        guard state.tasks.contains(where: { $0.id == "integration_n8n" }) else { return }
        if !didBaselineNotice {
            didBaselineNotice = true
            return
        }

        let summary = detail?.split(separator: "\n").first.map(String.init) ?? ""
        state.presentNotice(
            pillId: "integration_n8n",
            status: CoucouL10n.string(success ? "Finished" : "Failed"),
            headline: name,
            detail: summary,
            isFailure: !success
        )

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
