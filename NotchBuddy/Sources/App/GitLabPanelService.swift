import Foundation

/// What one read of GitLab gives the panel. Values only, so it crosses threads.
struct GitLabCacheEntry: Sendable {
    var updatedAt: String
    var entry: GitLabEntry
}

struct GitLabFetchResult: Sendable {
    var dashboard: GitLabDashboard
    var cache: [String: GitLabCacheEntry]
}

/// How an answer or a resolve went: nil is fine, else one of "empty", "no_token",
/// "forbidden", "not_found", "network", "error".
typealias GitLabSendError = String

/// Reads GitLab for the merge request panel (the user's merge requests across every
/// project, and the threads waiting for an answer) and carries what the panel sends
/// back: an answer, a resolve. Every 5 minutes, every minute while the panel is open,
/// and right after something was sent. Parsing and rules are in GitLabDash.swift.
///
/// Reading is done on background queues, a few merge requests at a time, and only for
/// what moved since the last time (or still runs a pipeline); the main actor keeps
/// the cache and the dashboard. Same endpoints as windows/src-tauri/src/gitlab_panel.rs.
@MainActor
final class GitLabPanelService {
    static let shared = GitLabPanelService()
    static let pillId = "integration_gitlab"

    /// Merge requests read at a time, and merge requests taken from my events.
    private static let perimeter = 30
    private static let eventCandidates = 15

    private var inFlight = false
    private var nextRead: DispatchWorkItem?
    /// Bumped when the token or the instance changes: an answer for the old one is dropped.
    private var generation = 0
    private var cache: [String: GitLabCacheEntry] = [:]
    /// Threads the user opened again himself: coming back is no news to alert on.
    private var reopened = Set<String>()
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        schedule(after: 12)
    }

    // MARK: - Scheduling

    private var interval: Double { GitLabPanelController.shared.isOpen ? 60 : 300 }

    private func schedule(after delay: Double? = nil) {
        nextRead?.cancel()
        let work = DispatchWorkItem { [weak self] in
            // Fired on the main queue: the class is main-actor isolated.
            MainActor.assumeIsolated { self?.read() }
        }
        nextRead = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (delay ?? interval), execute: work)
    }

    /// Reads now (the panel was just opened, something was sent).
    func refreshNow() {
        nextRead?.cancel()
        nextRead = nil
        read()
    }

    private func read() {
        guard !DemoEngine.isPollerPaused else { schedule(); return }
        guard !inFlight else { return }
        guard AppState.shared.activeIntegrations.contains(Self.pillId),
              let token = KeychainStore.shared.get("gitlab-token"),
              let base = GitLabPoller.baseURL else {
            schedule()
            return
        }
        inFlight = true
        let gen = generation
        let snapshot = cache
        DispatchQueue.global(qos: .background).async {
            let result = Self.fetch(token: token, base: base, cache: snapshot)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { GitLabPanelService.shared.finish(result, generation: gen) }
            }
        }
    }

    private func finish(_ result: GitLabFetchResult?, generation gen: Int) {
        inFlight = false
        defer { schedule() }
        // The token or the instance changed while this was in flight.
        guard gen == generation, let result else { return }
        cache = result.cache
        let model = GitLabPanelModel.shared
        var events = GitLab.events(old: model.dashboard, new: result.dashboard)
        events.removeAll { event in
            if case .commentPending(let id) = event { return reopened.remove(id) != nil }
            return false
        }
        model.receive(result.dashboard)
        if !events.isEmpty && AppState.shared.activeIntegrations.contains(Self.pillId) {
            AppState.shared.handleGitHubEvents(events, pillId: Self.pillId)
        }
    }

    /// The token or the instance changed: forget what the old one read.
    func credentialsChanged() {
        generation += 1
        cache = [:]
        GitLabPanelModel.shared.receive(nil)
        if KeychainStore.shared.get("gitlab-token") == nil {
            GitLabPanelController.shared.close()
        } else {
            refreshNow()
        }
    }

    /// The GitLab pill was switched off: the panel goes with it.
    func pillOff() {
        cache = [:]
        GitLabPanelModel.shared.receive(nil)
        GitLabPanelController.shared.close()
    }

    // MARK: - Reading

    private static func key(_ project: Int, _ iid: Int) -> String { "\(project)!\(iid)" }

    /// Runs `jobs` side by side and gives their answers back in order.
    private nonisolated static func parallel(_ jobs: [@Sendable () -> Any?]) -> [Any?] {
        let box = GitLabPoller.Collector<Any?>()
        DispatchQueue.concurrentPerform(iterations: jobs.count) { i in box.set(i, jobs[i]()) }
        let all = box.all
        return (0..<jobs.count).map { all[$0] ?? nil }
    }

    /// One merge request, read whole: its detail (the pipeline), its approvals when
    /// they matter, and its discussions.
    private nonisolated static func readEntry(base: String, token: String, project: Int, iid: Int,
                                              withApprovals: Bool, me: String) -> GitLabCacheEntry? {
        let api = GitLabPoller.shared
        let path = "projects/\(project)/merge_requests/\(iid)"
        guard let detail = api.get(base: base, token: token, path: path) as? [String: Any],
              let updated = detail["updated_at"] as? String else { return nil }
        let approvals = withApprovals ? api.get(base: base, token: token, path: "\(path)/approvals") as? [String: Any] : nil
        // Oldest first: the newest threads are on the last page.
        var discussions: [[String: Any]] = []
        for page in 1...3 {
            guard let batch = api.get(base: base, token: token, path: "\(path)/discussions",
                                      query: ["per_page": "100", "page": "\(page)"]) as? [[String: Any]] else { break }
            discussions.append(contentsOf: batch)
            if batch.count < 100 { break }
        }
        guard let entry = GitLab.buildEntry(detail: detail, approvals: approvals, discussions: discussions, me: me)
        else { return nil }
        return GitLabCacheEntry(updatedAt: updated, entry: entry)
    }

    private nonisolated static func fetch(token: String, base: String,
                                          cache cacheIn: [String: GitLabCacheEntry]) -> GitLabFetchResult? {
        let api = GitLabPoller.shared
        guard let user = api.get(base: base, token: token, path: "user") as? [String: Any],
              let me = user["username"] as? String else { return nil }
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        let approvedAfter = GitLab.dateDaysAgo(nowMs: nowMs, days: 60)
        let commentedAfter = GitLab.dateDaysAgo(nowMs: nowMs, days: 14)

        let openQuery = ["state": "opened", "order_by": "updated_at", "per_page": "30"]
        func list(_ extra: [String: String]) -> @Sendable () -> Any? {
            let query = openQuery.merging(extra) { _, new in new }
            return { api.get(base: base, token: token, path: "merge_requests", query: query) }
        }
        func events(_ action: String, _ after: String) -> @Sendable () -> Any? {
            { api.get(base: base, token: token, path: "events",
                      query: ["action": action, "after": after, "per_page": "100"]) }
        }
        let answers = parallel([
            list(["scope": "created_by_me"]),
            list(["scope": "all", "reviewer_username": me]),
            list(["scope": "assigned_to_me"]),
            events("approved", approvedAfter),
            events("commented", commentedAfter),
            { api.get(base: base, token: token, path: "personal_access_tokens/self") },
        ])
        // Without my own merge requests there is nothing to build on.
        guard answers[0] is [[String: Any]] else { return nil }
        let scopes = (answers[5] as? [String: Any])?["scopes"] as? [String]
        let canWrite = scopes.map { $0.contains("api") }

        // The perimeter: merge requests from the lists (newest first), then those my
        // events point at.
        var roles: [String: GitLabRoles] = [:]
        var updated: [String: String] = [:]
        var authors: [String: String] = [:]
        var listed: [(at: String, key: String)] = []
        for (i, answer) in [answers[0], answers[1], answers[2]].enumerated() {
            for item in (answer as? [[String: Any]]) ?? [] {
                guard let project = item["project_id"] as? Int, let iid = item["iid"] as? Int else { continue }
                let k = key(project, iid)
                switch i {
                case 1: roles[k, default: GitLabRoles()].reviewer = true
                case 2: roles[k, default: GitLabRoles()].assigned = true
                default: break
                }
                if let at = item["updated_at"] as? String, updated.updateValue(at, forKey: k) == nil {
                    listed.append((at, k))
                }
                if let a = (item["author"] as? [String: Any])?["username"] as? String { authors[k] = a }
            }
        }
        listed.sort { $0.at > $1.at }
        var order = listed.map { $0.key }
        let approvedKeys = GitLab.eventTargets(answers[3], max: eventCandidates)
        let commentedKeys = GitLab.eventTargets(answers[4], max: eventCandidates)
        for t in approvedKeys { roles[key(t.project, t.iid), default: GitLabRoles()].approvedEvent = true }
        for t in approvedKeys + commentedKeys {
            let k = key(t.project, t.iid)
            if !order.contains(k) { order.append(k) }
        }
        order = Array(order.prefix(perimeter))

        // Read again only what moved since the last time (or still runs a pipeline).
        var cache = cacheIn
        var toRead: [(key: String, project: Int, iid: Int, withApprovals: Bool)] = []
        for k in order {
            if GitLab.isFresh(cached: cache[k].map { ($0.updatedAt, $0.entry) }, updatedAt: updated[k]) { continue }
            let parts = k.split(separator: "!").compactMap { Int($0) }
            guard parts.count == 2 else { continue }
            // Approvals: for my merge requests ("1/2") and to know if I approved.
            let withApprovals = (roles[k]?.approvedEvent ?? false) || authors[k] == me
            toRead.append((k, parts[0], parts[1], withApprovals))
        }
        let reads = parallel(toRead.map { job -> @Sendable () -> Any? in
            { readEntry(base: base, token: token, project: job.project, iid: job.iid,
                        withApprovals: job.withApprovals, me: me) }
        })
        for (job, read) in zip(toRead, reads) {
            // A merge request that cannot be read (gone, no access) is not shown.
            if let read = read as? GitLabCacheEntry { cache[job.key] = read } else { cache[job.key] = nil }
        }
        cache = cache.filter { order.contains($0.key) }

        let entries = order.compactMap { k -> (entry: GitLabEntry, roles: GitLabRoles)? in
            guard let c = cache[k] else { return nil }
            return (c.entry, roles[k] ?? GitLabRoles())
        }
        let dashboard = GitLab.buildDashboard(me: me, baseURL: base, canWrite: canWrite, entries: entries, nowMs: nowMs)
        return GitLabFetchResult(dashboard: dashboard, cache: cache)
    }

    // MARK: - Answering

    /// Characters that need no escaping in a form value or a path segment.
    private nonisolated static let unreserved = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    private nonisolated static func errorCode(forStatus status: Int) -> GitLabSendError {
        switch status {
        case 0: return "network"
        case 401, 403: return "forbidden"
        case 404: return "not_found"
        default: return "error"
        }
    }

    /// POST or PUT with a form body, blocking: only called from background queues.
    private nonisolated static func write(method: String, path: String, form: [String: String]) -> GitLabSendError? {
        guard let token = KeychainStore.shared.get("gitlab-token"), let base = GitLabPoller.baseURL,
              let url = URL(string: GitLab.apiURL(base: base, path: path)) else { return "no_token" }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = method
        req.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")"
        }.sorted().joined(separator: "&")
        req.httpBody = Data(body.utf8)

        let reply = GitLabPoller.Reply()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, response, _ in
            reply.code = (response as? HTTPURLResponse)?.statusCode ?? 0
            done.signal()
        }.resume()
        done.wait()
        if (200..<300).contains(reply.code) { return nil }
        appendAppLog("gitlab.log", "\(path) HTTP \(reply.code)")
        return errorCode(forStatus: reply.code)
    }

    /// Answers in a thread. Only on a click in the panel, never by itself. The thread
    /// leaves the list at once; the next read confirms it.
    func reply(to thread: GitLabThread, body: String, completion: @escaping @MainActor (GitLabSendError?) -> Void) {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { completion("empty"); return }
        let path = "projects/\(thread.projectId)/merge_requests/\(thread.mrIid)/discussions/\(thread.id)/notes"
        DispatchQueue.global(qos: .userInitiated).async {
            let error = Self.write(method: "POST", path: path, form: ["body": text])
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if error == nil { GitLabPanelService.shared.sent(thread) }
                    completion(error)
                }
            }
        }
    }

    /// Resolves a thread, or opens it again.
    func resolve(_ thread: GitLabThread, resolved: Bool, completion: @escaping @MainActor (GitLabSendError?) -> Void) {
        let path = "projects/\(thread.projectId)/merge_requests/\(thread.mrIid)/discussions/\(thread.id)"
        DispatchQueue.global(qos: .userInitiated).async {
            let error = Self.write(method: "PUT", path: path, form: ["resolved": resolved ? "true" : "false"])
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if error == nil {
                        if !resolved { GitLabPanelService.shared.reopened.insert(thread.id) }
                        GitLabPanelService.shared.sent(thread)
                    }
                    completion(error)
                }
            }
        }
    }

    private func sent(_ thread: GitLabThread) {
        cache[Self.key(thread.projectId, thread.mrIid)] = nil
        GitLabPanelModel.shared.drop(thread: thread.id)
        refreshNow()
    }

    /// The lines around a code comment, read from the file at the commit it was made on.
    func snippet(for thread: GitLabThread, completion: @escaping @MainActor ([GitLabSnippetLine]?) -> Void) {
        guard let position = thread.position,
              let token = KeychainStore.shared.get("gitlab-token"), let base = GitLabPoller.baseURL,
              let file = position.file.addingPercentEncoding(withAllowedCharacters: Self.unreserved),
              let ref = position.sha.addingPercentEncoding(withAllowedCharacters: Self.unreserved),
              let url = URL(string: "\(base)/api/v4/projects/\(thread.projectId)/repository/files/\(file)/raw?ref=\(ref)")
        else { completion(nil); return }
        let line = position.line
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        URLSession.shared.dataTask(with: req) { data, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            // A huge file is not worth reading for a few lines.
            var lines: [GitLabSnippetLine]?
            if (200..<300).contains(code), let data, data.count <= 2_000_000,
               let text = String(data: data, encoding: .utf8) {
                lines = GitLab.snippet(text: text, line: line, context: 3)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(lines) } }
        }.resume()
    }
}
