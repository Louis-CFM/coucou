#if PHONE_LINK
import AppKit
import CloudKit

// MARK: - Services up close, for the iPhone
//
// When a service's screen opens on the iPhone, it writes a `ServiceAction`
// record of kind "refresh"; to act (redeploy, re-run, merge…) it writes one
// with that action's kind and target. The CloudKit push wakes this Mac (with
// a check every minute in case a push is missed); it takes each request once
// (deleted on read, and only those it could delete), reads the service's API
// with the key in its Keychain and writes a `ServiceDetail` record,
// encrypted. An action runs only if it was offered on an item of the last
// detail sent for that service, and was asked for in the last 5 minutes.
// Nothing that moves money or sends an email is ever offered.

@MainActor
final class ServiceDetailRunner {
    static let shared = ServiceDetailRunner()

    private var database: CKDatabase { CKContainer(identifier: CloudProbe.containerID).privateCloudDatabase }
    private var pollTask: Task<Void, Never>?
    private var changeToken: CKServerChangeToken?
    /// The last detail sent per service: actions are checked against it.
    private var lastDetails: [String: ServiceDetail] = [:]
    private let maxAge: TimeInterval = 5 * 60
    private var checking = false
    private var again = false

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkNow()
                // In case a push is missed.
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Stops and deletes the details this Mac wrote to iCloud.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        lastDetails = [:]
        let ids = PillCatalog.phoneServices.map {
            CKRecord.ID(recordName: ServiceDetail.recordName(for: $0), zoneID: SessionSnapshot.zoneID)
        }
        Task { _ = try? await database.modifyRecords(saving: [], deleting: ids, savePolicy: .changedKeys, atomically: false) }
    }

    /// From the CloudKit push and the fallback check. One check at a time: two
    /// overlapping checks would share the change token and could run an action twice.
    func checkNow() async {
        guard pollTask != nil else { return }
        guard !checking else { again = true; return }
        checking = true
        repeat {
            again = false
            await check()
        } while again
        checking = false
    }

    // MARK: Requests

    private func check() async {
        var found: [CKRecord] = []
        do {
            var more = true
            while more {
                let changes = try await database.recordZoneChanges(inZoneWith: SessionSnapshot.zoneID, since: changeToken,
                                                                   desiredKeys: ["pillId", "kind", "requestedAt", "target"])
                for (_, result) in changes.modificationResultsByID {
                    if case .success(let mod) = result, mod.record.recordType == ServiceDetail.requestType {
                        found.append(mod.record)
                    }
                }
                changeToken = changes.changeToken
                more = changes.moreComing
            }
        } catch let error as CKError where error.code == .changeTokenExpired {
            changeToken = nil
            return
        } catch {
            return
        }
        guard !found.isEmpty else { return }
        // Single use: act only on the requests this Mac actually removed from iCloud.
        guard let removed = try? await database.modifyRecords(saving: [], deleting: found.map(\.recordID),
                                                              savePolicy: .changedKeys, atomically: false) else {
            log("couldn't take \(found.count) request(s) off iCloud; skipped")
            return
        }
        let taken = found.filter {
            guard case .success? = removed.deleteResults[$0.recordID] else { return false }
            return true
        }

        // Several refreshes for one service count once.
        var refreshed: Set<String> = []
        for record in taken.sorted(by: { ($0["requestedAt"] as? Date ?? .distantPast) < ($1["requestedAt"] as? Date ?? .distantPast) }) {
            let pillId = record["pillId"] as? String ?? ""
            let kind = record["kind"] as? String ?? ""
            let target = record.encryptedValues["target"] as? String ?? ""
            let requestedAt = record["requestedAt"] as? Date ?? .distantPast
            guard Date().timeIntervalSince(requestedAt) < maxAge, PillCatalog.phoneServices.contains(pillId) else { continue }
            if kind == ServiceDetail.refreshKind {
                guard refreshed.insert(pillId).inserted else { continue }
                await publish(pillId: pillId, lastAction: lastDetails[pillId]?.lastAction)
            } else {
                await run(kind: kind, target: target, pillId: pillId)
            }
        }
    }

    private func run(kind: String, target: String, pillId: String) async {
        guard let action = lastDetails[pillId]?.offered(kind: kind, target: target),
              ServiceAPI.allowedKinds.contains(kind), kind.hasPrefix(ServiceAPI.prefix(of: pillId)) else {
            log("ignored an action that wasn't offered: \(kind)")
            await publish(pillId: pillId, lastAction: ServiceActionResult(
                title: "Not done", ok: false,
                message: "This action isn't offered any more. The list was refreshed.", date: Date()))
            return
        }
        log("\(action.title) (\(pillId)) asked from the iPhone")
        let result: ServiceActionResult
        do {
            let message = try await ServiceAPI.perform(kind: kind, target: target)
            result = ServiceActionResult(title: action.title, ok: true, message: message, date: Date())
        } catch {
            result = ServiceActionResult(title: action.title, ok: false, message: ServiceAPI.describe(error), date: Date())
        }
        log("\(action.title): \(result.ok ? "done" : "failed, \(result.message)")")
        // Give the service a moment, then show where things are.
        try? await Task.sleep(for: .seconds(2))
        await publish(pillId: pillId, lastAction: result)
    }

    private func publish(pillId: String, lastAction: ServiceActionResult?) async {
        var detail = await ServiceAPI.detail(for: pillId)
        // The iPhone sync was turned off while the API was read: write nothing.
        guard !Task.isCancelled, pollTask != nil else { return }
        detail.lastAction = lastAction
        lastDetails[pillId] = detail
        guard let json = try? JSONEncoder().encode(detail), let payload = String(data: json, encoding: .utf8) else { return }
        let record = CKRecord(recordType: ServiceDetail.recordType,
                              recordID: CKRecord.ID(recordName: ServiceDetail.recordName(for: pillId), zoneID: SessionSnapshot.zoneID))
        record["pillId"] = pillId
        record["fetchedAt"] = detail.fetchedAt
        record.encryptedValues["payload"] = payload
        do {
            _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
        } catch {
            log("detail for \(pillId) not saved: \(error.localizedDescription)")
        }
    }

    private func log(_ message: String) {
        CloudProbe.shared.log("[services] \(message)")
    }
}

// MARK: - The services' APIs

enum ServiceAPI {
    struct Failure: Error {
        let status: Int
        let message: String
    }

    /// Every action the iPhone can ask for. Nothing moves money or sends an email.
    static let allowedKinds: Set<String> = [
        "vercel.redeploy", "vercel.promote", "vercel.cancel",
        "github.rerun", "github.approve", "github.merge",
        "n8n.activate", "n8n.deactivate", "n8n.retry",
    ]

    static func prefix(of pillId: String) -> String {
        pillId.replacingOccurrences(of: "integration_", with: "") + "."
    }

    static func describe(_ error: Error) -> String {
        if let failure = error as? Failure {
            switch failure.status {
            case 401:
                if failure.message.localizedCaseInsensitiveContains("restricted") {
                    // Resend `restricted_api_key`: a Sending-access key can't read emails or domains.
                    return "This key can only send emails. Use a Full access key in Coucou's Settings on your Mac to see them here."
                }
                return "The key was refused (401). Check it in Coucou's Settings on your Mac."
            case 403: return "Not allowed with this key (403). \(failure.message)"
            case 404: return "Not found (404)."
            default: return failure.message.isEmpty ? "Error \(failure.status)" : String(failure.message.prefix(160))
            }
        }
        return error.localizedDescription
    }

    // MARK: HTTP

    private static func request(_ urlString: String, method: String = "GET", headers: [String: String],
                                body: [String: Any]? = nil) async throws -> Any {
        guard let url = URL(string: urlString) else { throw Failure(status: 0, message: "Bad address") }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = (json?["message"] as? String)
                ?? ((json?["error"] as? [String: Any])?["message"] as? String)
                ?? (json?["error"] as? String)
                ?? String(decoding: data.prefix(200), as: UTF8.self)
            throw Failure(status: status, message: message)
        }
        if data.isEmpty { return [String: Any]() }
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func date(_ value: Any?) -> Date? {
        if let ms = value as? Double { return Date(timeIntervalSince1970: ms > 1e11 ? ms / 1000 : ms) }
        if let ms = value as? Int { return Date(timeIntervalSince1970: ms > 100_000_000_000 ? Double(ms) / 1000 : Double(ms)) }
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        // Resend: "2024-05-01 10:00:00.123456+00"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss.SSSSSSZ", "yyyy-MM-dd HH:mm:ss.SSSZ", "yyyy-MM-dd HH:mm:ssZ"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text.count > 3 && text.hasSuffix("+00") ? text + "00" : text) { return date }
        }
        return nil
    }

    private static func money(_ cents: Int, _ currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.uppercased()
        // Stripe zero-decimal currencies (docs.stripe.com/currencies#zero-decimal). UGX and ISK stay ×100
        // for backward compatibility; HUF and TWD charges are two-decimal.
        let zeroDecimal: Set<String> = ["bif", "clp", "djf", "gnf", "jpy", "kmf", "krw", "mga", "pyg", "rwf",
                                        "vnd", "vuv", "xaf", "xof", "xpf"]
        let amount = zeroDecimal.contains(currency.lowercased()) ? Double(cents) : Double(cents) / 100
        return formatter.string(from: NSNumber(value: amount)) ?? "\(amount) \(currency.uppercased())"
    }

    // MARK: Reading

    static func detail(for pillId: String) async -> ServiceDetail {
        do {
            switch pillId {
            case "integration_vercel": return try await vercel()
            case "integration_github": return try await github()
            case "integration_stripe": return try await stripe()
            case "integration_resend": return try await resend()
            case "integration_calcom": return try await calcom()
            case "integration_n8n": return try await n8n()
            case "integration_notion": return try await notion()
            default: return ServiceDetail(pillId: pillId, fetchedAt: Date(), error: "Not available from the iPhone yet.")
            }
        } catch {
            return ServiceDetail(pillId: pillId, fetchedAt: Date(), error: describe(error))
        }
    }

    private static func secret(_ name: String, _ service: String) throws -> String {
        guard let value = KeychainStore.shared.get(name), !value.isEmpty else {
            throw Failure(status: 0, message: "No \(service) key on your Mac. Add it in Coucou's Settings.")
        }
        return value
    }

    // Vercel: deployments (redeploy, promote to production, cancel) and projects.
    private static func vercel() async throws -> ServiceDetail {
        let token = try secret("vercel-token", "Vercel")
        let headers = ["Authorization": "Bearer \(token)", "Accept": "application/json"]
        let deploymentsJSON = try await request(VercelAPI.url("https://api.vercel.com/v6/deployments?limit=20"), headers: headers)
        let deployments = (deploymentsJSON as? [String: Any])?["deployments"] as? [[String: Any]] ?? []
        let projectsJSON = try? await request(VercelAPI.url("https://api.vercel.com/v9/projects?limit=20"), headers: headers)
        let projects = (projectsJSON as? [String: Any])?["projects"] as? [[String: Any]] ?? []

        var items: [DetailItem] = []
        var ready = 0, failed = 0, building = 0
        for d in deployments {
            guard let uid = d["uid"] as? String else { continue }
            let name = d["name"] as? String ?? "Deployment"
            let state = (d["state"] as? String ?? d["readyState"] as? String ?? "").uppercased()
            let target = d["target"] as? String
            let meta = d["meta"] as? [String: Any] ?? [:]
            let message = meta["githubCommitMessage"] as? String ?? ""
            let branch = meta["githubCommitRef"] as? String ?? ""
            let creator = (d["creator"] as? [String: Any])?["username"] as? String ?? ""
            var tone: ServiceTone = .idle
            var actions: [ServiceActionDef] = []
            switch state {
            case "READY":
                ready += 1
                tone = .ok
                actions.append(ServiceActionDef(kind: "vercel.redeploy", title: "Redeploy", symbol: "arrow.clockwise",
                                                target: "\(uid)|\(name)|\(target ?? "")"))
                if target != "production" {
                    actions.append(ServiceActionDef(kind: "vercel.promote", title: "Promote to production",
                                                    symbol: "arrow.up.circle", target: "\(uid)|\(name)",
                                                    confirm: "A new production build starts from this deployment, using your production environment variables."))
                }
            case "ERROR":
                failed += 1
                tone = .error
                actions.append(ServiceActionDef(kind: "vercel.redeploy", title: "Redeploy", symbol: "arrow.clockwise",
                                                target: "\(uid)|\(name)|\(target ?? "")"))
            case "BUILDING", "QUEUED", "INITIALIZING":
                building += 1
                tone = .warning
                actions.append(ServiceActionDef(kind: "vercel.cancel", title: "Cancel build", symbol: "xmark.circle",
                                                target: uid, destructive: true, confirm: "Stop this build?"))
            case "CANCELED": tone = .idle
            default: break
            }
            let subtitle = [branch, message.split(separator: "\n").first.map(String.init) ?? "", creator]
                .filter { !$0.isEmpty }.joined(separator: " · ")
            items.append(DetailItem(title: name, subtitle: subtitle.isEmpty ? state.capitalized : subtitle, tone: tone,
                                    date: date(d["created"] ?? d["createdAt"]),
                                    url: (d["url"] as? String).map { "https://\($0)" },
                                    badge: target == "production" ? "Production" : (state == "READY" ? "Preview" : state.capitalized),
                                    actions: actions))
        }
        let projectItems = projects.prefix(20).map { p in
            DetailItem(title: p["name"] as? String ?? "Project",
                       subtitle: (p["framework"] as? String).map { $0.capitalized } ?? "",
                       date: date(p["updatedAt"]))
        }
        var sections = [DetailSection(title: "Deployments", items: items)]
        if !projectItems.isEmpty { sections.append(DetailSection(title: "Projects · \(projectItems.count)", items: Array(projectItems))) }
        return ServiceDetail(pillId: "integration_vercel",
                             stats: [DetailStat(label: "Ready", value: "\(ready)", tone: .ok),
                                     DetailStat(label: "Building", value: "\(building)", tone: building > 0 ? .warning : .idle),
                                     DetailStat(label: "Failed", value: "\(failed)", tone: failed > 0 ? .error : .idle),
                                     DetailStat(label: "Projects", value: "\(projects.count)")],
                             sections: sections, fetchedAt: Date())
    }

    // GitHub: your pull requests (merge), reviews asked of you (approve), CI runs (re-run failed jobs).
    private static func github() async throws -> ServiceDetail {
        let token = try secret("github-token", "GitHub")
        let headers = ["Authorization": "Bearer \(token)", "Accept": "application/vnd.github+json",
                       "X-GitHub-Api-Version": "2022-11-28"]
        let user = try await request("https://api.github.com/user", headers: headers) as? [String: Any] ?? [:]
        let login = user["login"] as? String ?? ""

        func search(_ query: String) async -> [[String: Any]] {
            var components = URLComponents(string: "https://api.github.com/search/issues")!
            components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "per_page", value: "10"),
                                     URLQueryItem(name: "sort", value: "updated")]
            let json = try? await request(components.url!.absoluteString, headers: headers)
            return (json as? [String: Any])?["items"] as? [[String: Any]] ?? []
        }
        /// "owner/repo#12" from a search result.
        func pullRef(_ item: [String: Any]) -> String? {
            guard let repoURL = item["repository_url"] as? String, let number = item["number"] as? Int else { return nil }
            let parts = repoURL.split(separator: "/").suffix(2).joined(separator: "/")
            return "\(parts)#\(number)"
        }

        let mine = await search("is:pr is:open author:\(login) archived:false")
        let asked = await search("is:pr is:open review-requested:\(login) archived:false")

        let mineItems = mine.compactMap { item -> DetailItem? in
            guard let ref = pullRef(item) else { return nil }
            let draft = item["draft"] as? Bool ?? false
            return DetailItem(title: item["title"] as? String ?? "Pull request", subtitle: ref,
                              tone: draft ? .idle : .info, date: date(item["updated_at"]),
                              url: item["html_url"] as? String, badge: draft ? "Draft" : nil,
                              actions: draft ? [] : [ServiceActionDef(kind: "github.merge", title: "Squash and merge",
                                                                      symbol: "arrow.triangle.merge", target: ref,
                                                                      confirm: "Merge \(ref) into its base branch?")])
        }
        let askedItems = asked.compactMap { item -> DetailItem? in
            guard let ref = pullRef(item) else { return nil }
            let author = (item["user"] as? [String: Any])?["login"] as? String ?? ""
            return DetailItem(title: item["title"] as? String ?? "Pull request",
                              subtitle: author.isEmpty ? ref : "\(ref) · \(author)", tone: .warning,
                              date: date(item["updated_at"]), url: item["html_url"] as? String,
                              actions: [ServiceActionDef(kind: "github.approve", title: "Approve", symbol: "checkmark.seal",
                                                         target: ref)])
        }

        // CI on the repos you pushed to last.
        let reposJSON = try? await request("https://api.github.com/user/repos?sort=pushed&per_page=5&affiliation=owner,collaborator",
                                           headers: headers)
        let repos = (reposJSON as? [[String: Any]] ?? []).compactMap { $0["full_name"] as? String }
        var runItems: [DetailItem] = []
        var failing = 0
        for repo in repos {
            let runsJSON = try? await request("https://api.github.com/repos/\(repo)/actions/runs?per_page=3", headers: headers)
            let runs = (runsJSON as? [String: Any])?["workflow_runs"] as? [[String: Any]] ?? []
            for run in runs {
                guard let id = run["id"] as? Int else { continue }
                let status = run["status"] as? String ?? ""
                let conclusion = run["conclusion"] as? String ?? ""
                var tone: ServiceTone = .idle
                var actions: [ServiceActionDef] = []
                if status != "completed" {
                    tone = .warning
                } else if conclusion == "success" {
                    tone = .ok
                } else if conclusion == "failure" || conclusion == "timed_out" {
                    tone = .error
                    failing += 1
                    actions.append(ServiceActionDef(kind: "github.rerun", title: "Re-run failed jobs",
                                                    symbol: "arrow.clockwise", target: "\(repo)/\(id)"))
                }
                let label = status == "completed" ? conclusion.replacingOccurrences(of: "_", with: " ") : status.replacingOccurrences(of: "_", with: " ")
                runItems.append(DetailItem(title: run["name"] as? String ?? "Workflow",
                                           subtitle: "\(repo) · \(run["head_branch"] as? String ?? "")",
                                           tone: tone, date: date(run["created_at"]),
                                           url: run["html_url"] as? String, badge: label.capitalized, actions: actions))
            }
        }

        var sections: [DetailSection] = []
        if !askedItems.isEmpty { sections.append(DetailSection(title: "Reviews asked of you", items: askedItems)) }
        sections.append(DetailSection(title: "Your pull requests", items: mineItems,
                                      footer: mineItems.isEmpty ? "No open pull request." : nil))
        if !runItems.isEmpty { sections.append(DetailSection(title: "CI on your latest repos", items: runItems)) }
        return ServiceDetail(pillId: "integration_github",
                             stats: [DetailStat(label: "Your PRs", value: "\(mineItems.count)", tone: .info),
                                     DetailStat(label: "Reviews", value: "\(askedItems.count)", tone: askedItems.isEmpty ? .idle : .warning),
                                     DetailStat(label: "CI failing", value: "\(failing)", tone: failing > 0 ? .error : .ok)],
                             sections: sections, fetchedAt: Date())
    }

    // Stripe: balance, payments, payouts, subscriptions. Read only.
    private static func stripe() async throws -> ServiceDetail {
        let key = try secret("stripe-api-key", "Stripe")
        let headers = ["Authorization": "Bearer \(key)"]
        let balance = try await request("https://api.stripe.com/v1/balance", headers: headers) as? [String: Any] ?? [:]
        // One entry per currency in each list, in no set order: pair them by currency.
        let availableList = balance["available"] as? [[String: Any]] ?? []
        let pendingList = balance["pending"] as? [[String: Any]] ?? []
        let currency = ((availableList.first ?? pendingList.first)?["currency"] as? String ?? "eur").lowercased()
        func amount(_ list: [[String: Any]]) -> Int {
            list.first { ($0["currency"] as? String)?.lowercased() == currency }?["amount"] as? Int ?? 0
        }
        let available = amount(availableList)
        let pending = amount(pendingList)

        /// A list, or why it couldn't be read (shown instead of a made-up zero).
        func list(_ path: String) async -> ([[String: Any]], [String: Any], String?) {
            do {
                let json = try await request("https://api.stripe.com/v1/\(path)", headers: headers) as? [String: Any] ?? [:]
                return (json["data"] as? [[String: Any]] ?? [], json, nil)
            } catch {
                return ([], [:], describe(error))
            }
        }

        let (charges, _, chargesError) = await list("charges?limit=15")
        let chargeItems = charges.map { c -> DetailItem in
            let status = c["status"] as? String ?? ""
            let refunded = c["refunded"] as? Bool ?? false
            let partlyRefunded = !refunded && (c["amount_refunded"] as? Int ?? 0) > 0
            let uncaptured = !refunded && status == "succeeded" && (c["captured"] as? Bool) == false
            let who = ((c["billing_details"] as? [String: Any])?["name"] as? String)
                ?? (c["receipt_email"] as? String) ?? (c["description"] as? String) ?? ""
            let tone: ServiceTone = refunded ? .idle
                : (uncaptured || partlyRefunded) ? .warning
                : status == "succeeded" ? .ok : status == "failed" ? .error : .warning
            let badge = refunded ? "Refunded" : uncaptured ? "Uncaptured"
                : partlyRefunded ? "Partly refunded" : status.capitalized
            return DetailItem(title: money(c["amount"] as? Int ?? 0, c["currency"] as? String ?? currency),
                              subtitle: who, tone: tone, date: date(c["created"]), badge: badge)
        }
        let (payouts, _, payoutsError) = await list("payouts?limit=5")
        let payoutItems = payouts.map { p in
            DetailItem(title: money(p["amount"] as? Int ?? 0, p["currency"] as? String ?? currency),
                       subtitle: "Arrives", tone: (p["status"] as? String) == "failed" ? .error : .info,
                       date: date(p["arrival_date"]), badge: (p["status"] as? String)?.replacingOccurrences(of: "_", with: " ").capitalized)
        }

        // Active subscriptions, every page (up to 1 000).
        var subs: [[String: Any]] = []
        var moreSubs = false
        var subsError: String?
        var cursor: String?
        for _ in 0..<10 {
            let (page, json, error) = await list("subscriptions?status=active&limit=100" + (cursor.map { "&starting_after=\($0)" } ?? ""))
            if let error { subsError = error; break }
            subs += page
            moreSubs = json["has_more"] as? Bool ?? false
            guard moreSubs, let last = subs.last?["id"] as? String else { break }
            cursor = last
        }
        // Estimated monthly revenue, one total per currency. Metered and tiered
        // prices have no fixed amount per period and discounts aren't applied.
        var monthlyByCurrency: [String: Double] = [:]
        for sub in subs {
            let subCurrency = (sub["currency"] as? String)?.lowercased()
            let items = (sub["items"] as? [String: Any])?["data"] as? [[String: Any]] ?? []
            for item in items {
                let price = item["price"] as? [String: Any] ?? [:]
                let recurring = price["recurring"] as? [String: Any] ?? [:]
                if recurring["usage_type"] as? String == "metered" || price["billing_scheme"] as? String == "tiered" { continue }
                let perUnit = (price["unit_amount"] as? Int).map { Double($0) }
                    ?? Double(price["unit_amount_decimal"] as? String ?? "") ?? 0
                let unit = perUnit * Double(item["quantity"] as? Int ?? 1)
                let count = Double(recurring["interval_count"] as? Int ?? 1)
                let perMonth: Double
                switch recurring["interval"] as? String {
                case "year": perMonth = unit / (12 * count)
                case "week": perMonth = unit * 4.345 / count
                case "day": perMonth = unit * 30.4 / count
                default: perMonth = unit / count
                }
                let itemCurrency = subCurrency ?? (price["currency"] as? String)?.lowercased() ?? currency
                monthlyByCurrency[itemCurrency, default: 0] += perMonth
            }
        }
        let largest = monthlyByCurrency.max { $0.value < $1.value }
        let mrrCurrency = monthlyByCurrency[currency] != nil ? currency : (largest?.key ?? currency)
        let monthly = monthlyByCurrency[mrrCurrency] ?? 0

        var sections = [DetailSection(title: "Payments", items: chargeItems, footer: chargesError)]
        if !payoutItems.isEmpty || payoutsError != nil {
            sections.append(DetailSection(title: "Payouts", items: payoutItems, footer: payoutsError))
        }
        if let subsError { sections.append(DetailSection(title: "Subscriptions", items: [], footer: subsError)) }
        return ServiceDetail(pillId: "integration_stripe",
                             stats: [DetailStat(label: "Available", value: money(available, currency), tone: .ok),
                                     DetailStat(label: "Pending", value: money(pending, currency)),
                                     DetailStat(label: "Subscriptions",
                                                value: subsError != nil ? "—" : (moreSubs ? "\(subs.count)+" : "\(subs.count)"),
                                                tone: .info),
                                     DetailStat(label: "Est. MRR",
                                                value: subsError != nil ? "—" : money(Int(monthly.rounded()), mrrCurrency),
                                                tone: .info)],
                             sections: sections, fetchedAt: Date())
    }

    // Resend: the latest emails and how they went, and the domains. Read only.
    private static func resend() async throws -> ServiceDetail {
        let key = try secret("resend-api-key", "Resend")
        let headers = ["Authorization": "Bearer \(key)"]
        let emailsJSON = try await request("https://api.resend.com/emails?limit=20", headers: headers)
        let emails = (emailsJSON as? [String: Any])?["data"] as? [[String: Any]] ?? []
        var bounced = 0, delivered = 0
        let emailItems = emails.map { e -> DetailItem in
            let event = e["last_event"] as? String ?? "sent"
            let tone: ServiceTone
            switch event {
            case "delivered", "opened", "clicked": tone = .ok; delivered += 1
            case "bounced", "complained", "failed", "suppressed": tone = .error; bounced += 1
            case "delivery_delayed": tone = .warning
            default: tone = .info
            }
            let to = (e["to"] as? [String])?.joined(separator: ", ") ?? ""
            return DetailItem(title: e["subject"] as? String ?? "(no subject)", subtitle: to, tone: tone,
                              date: date(e["created_at"]), badge: event.replacingOccurrences(of: "_", with: " ").capitalized)
        }
        let domainsJSON = try? await request("https://api.resend.com/domains", headers: headers)
        let domains = (domainsJSON as? [String: Any])?["data"] as? [[String: Any]] ?? []
        let domainItems = domains.map { d in
            let status = d["status"] as? String ?? ""
            return DetailItem(title: d["name"] as? String ?? "Domain", subtitle: d["region"] as? String ?? "",
                              tone: status == "verified" ? .ok : (status == "failed" ? .error : .warning),
                              badge: status.replacingOccurrences(of: "_", with: " ").capitalized)
        }
        var sections = [DetailSection(title: "Latest emails", items: emailItems)]
        if !domainItems.isEmpty { sections.append(DetailSection(title: "Domains", items: domainItems)) }
        return ServiceDetail(pillId: "integration_resend",
                             stats: [DetailStat(label: "Delivered", value: "\(delivered)", tone: .ok),
                                     DetailStat(label: "Bounced", value: "\(bounced)", tone: bounced > 0 ? .error : .idle),
                                     DetailStat(label: "Domains", value: "\(domains.count)")],
                             sections: sections, fetchedAt: Date())
    }

    // Cal.com: upcoming bookings. Read only: cancelling emails the guest and can refund or charge them.
    private static func calcom() async throws -> ServiceDetail {
        let key = try secret("calcom-api-key", "Cal.com")
        let headers = ["Authorization": "Bearer \(key)", "cal-api-version": "2024-08-13"]
        let iso = ISO8601DateFormatter()
        let now = Date()
        var components = URLComponents(string: "https://api.cal.com/v2/bookings")!
        components.queryItems = [URLQueryItem(name: "status", value: "upcoming"),
                                 URLQueryItem(name: "afterStart", value: iso.string(from: now)),
                                 URLQueryItem(name: "take", value: "30")]
        let json = try await request(components.url!.absoluteString, headers: headers)
        let bookings = (json as? [String: Any])?["data"] as? [[String: Any]] ?? []
        let calendar = Calendar.current
        var today = 0, week = 0
        let items = bookings.compactMap { b -> DetailItem? in
            guard let start = date(b["start"] ?? b["startTime"]) else { return nil }
            if calendar.isDateInToday(start) { today += 1 }
            if start.timeIntervalSince(now) < 7 * 24 * 3600 { week += 1 }
            let attendee = (b["attendees"] as? [[String: Any]])?.first
            let who = attendee?["name"] as? String ?? attendee?["email"] as? String ?? ""
            let when = start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
            return DetailItem(title: b["title"] as? String ?? "Meeting",
                              subtitle: who.isEmpty ? when : "\(when) · \(who)",
                              tone: calendar.isDateInToday(start) ? .warning : .info,
                              date: start, url: (b["meetingUrl"] as? String) ?? (b["location"] as? String).flatMap { $0.hasPrefix("https://") ? $0 : nil },
                              badge: (b["status"] as? String)?.capitalized)
        }
        return ServiceDetail(pillId: "integration_calcom",
                             stats: [DetailStat(label: "Today", value: "\(today)", tone: today > 0 ? .warning : .idle),
                                     DetailStat(label: "Next 7 days", value: "\(week)", tone: .info),
                                     DetailStat(label: "Upcoming", value: "\(items.count)")],
                             sections: [DetailSection(title: "Upcoming bookings", items: items,
                                                      footer: items.isEmpty ? "Nothing booked." : nil)],
                             fetchedAt: Date())
    }

    // n8n: workflows (activate, deactivate) and executions (retry a failed one).
    private static func n8n() async throws -> ServiceDetail {
        let key = try secret("n8n-api-key", "n8n")
        let base = try secret("n8n-url", "n8n").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let headers = ["X-N8N-API-KEY": key, "Accept": "application/json"]
        // The list comes in pages (at most 250, then `cursor` = the previous `nextCursor`): read
        // them all so the counts are right.
        var workflows: [[String: Any]] = []
        var cursor: String?
        repeat {
            var url = "\(base)/api/v1/workflows?limit=250"
            if let cursor, let encoded = cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
                url += "&cursor=\(encoded)"
            }
            let page = try await request(url, headers: headers) as? [String: Any]
            workflows += page?["data"] as? [[String: Any]] ?? []
            cursor = page?["nextCursor"] as? String
        } while !(cursor ?? "").isEmpty && workflows.count < 5_000
        var names: [String: String] = [:]
        var active = 0
        let workflowItems = workflows.compactMap { w -> DetailItem? in
            guard let id = (w["id"] as? String) ?? (w["id"] as? Int).map(String.init) else { return nil }
            let name = w["name"] as? String ?? "Workflow"
            names[id] = name
            // Archived workflows are listed but can't be turned on (n8n answers 400).
            if w["isArchived"] as? Bool ?? false { return nil }
            let isActive = w["active"] as? Bool ?? false
            if isActive { active += 1 }
            return DetailItem(title: name, tone: isActive ? .ok : .idle, date: date(w["updatedAt"]),
                              url: "\(base)/workflow/\(id)", badge: isActive ? "Active" : "Off",
                              actions: [isActive
                                        ? ServiceActionDef(kind: "n8n.deactivate", title: "Turn off", symbol: "pause.circle",
                                                           target: id, destructive: true, confirm: "Stop \(name) from running?")
                                        : ServiceActionDef(kind: "n8n.activate", title: "Turn on", symbol: "play.circle", target: id)])
        }
        let executionsJSON = try? await request("\(base)/api/v1/executions?limit=15", headers: headers)
        let executions = (executionsJSON as? [String: Any])?["data"] as? [[String: Any]] ?? []
        var failed = 0
        let executionItems = executions.compactMap { e -> DetailItem? in
            guard let id = (e["id"] as? String) ?? (e["id"] as? Int).map(String.init) else { return nil }
            let workflowId = (e["workflowId"] as? String) ?? (e["workflowId"] as? Int).map(String.init) ?? ""
            let status = e["status"] as? String ?? ((e["finished"] as? Bool ?? false) ? "success" : "error")
            let isFailure = status == "error" || status == "crashed" || status == "failed"
            if isFailure { failed += 1 }
            return DetailItem(title: names[workflowId] ?? "Workflow \(workflowId)", subtitle: "Execution \(id)",
                              tone: isFailure ? .error : (status == "success" ? .ok : .warning),
                              date: date(e["startedAt"]), url: "\(base)/workflow/\(workflowId)/executions/\(id)",
                              badge: status.capitalized,
                              actions: isFailure ? [ServiceActionDef(kind: "n8n.retry", title: "Retry", symbol: "arrow.clockwise", target: id)] : [])
        }
        return ServiceDetail(pillId: "integration_n8n",
                             stats: [DetailStat(label: "Workflows", value: "\(workflowItems.count)"),
                                     DetailStat(label: "Active", value: "\(active)", tone: .ok),
                                     DetailStat(label: "Failed runs", value: "\(failed)", tone: failed > 0 ? .error : .idle)],
                             sections: [DetailSection(title: "Latest runs", items: executionItems),
                                        DetailSection(title: "Workflows",
                                                      items: Array(workflowItems.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(50)))],
                             fetchedAt: Date())
    }

    // Notion: the pages and databases edited last. Read only.
    private static func notion() async throws -> ServiceDetail {
        let key = try secret("notion-api-key", "Notion")
        let headers = ["Authorization": "Bearer \(key)", "Notion-Version": "2022-06-28"]
        let json = try await request("https://api.notion.com/v1/search", method: "POST", headers: headers,
                                     body: ["sort": ["direction": "descending", "timestamp": "last_edited_time"], "page_size": 25])
        let results = (json as? [String: Any])?["results"] as? [[String: Any]] ?? []
        var pages: [DetailItem] = []
        var databases: [DetailItem] = []
        for object in results {
            let kind = object["object"] as? String ?? "page"
            var title = ""
            if kind == "database" {
                title = ((object["title"] as? [[String: Any]])?.compactMap { $0["plain_text"] as? String }.joined()) ?? ""
            } else if let properties = object["properties"] as? [String: Any] {
                for case let property as [String: Any] in properties.values where property["type"] as? String == "title" {
                    title = ((property["title"] as? [[String: Any]])?.compactMap { $0["plain_text"] as? String }.joined()) ?? ""
                }
            }
            var emoji = ""
            if let icon = object["icon"] as? [String: Any], icon["type"] as? String == "emoji" { emoji = (icon["emoji"] as? String ?? "") + " " }
            let item = DetailItem(title: emoji + (title.isEmpty ? "Untitled" : title),
                                  date: date(object["last_edited_time"]), url: object["url"] as? String,
                                  badge: (object["archived"] as? Bool ?? false) ? "Archived" : nil)
            if kind == "database" { databases.append(item) } else { pages.append(item) }
        }
        var sections = [DetailSection(title: "Edited lately", items: pages)]
        if !databases.isEmpty { sections.append(DetailSection(title: "Databases", items: databases)) }
        let editedToday = results.filter { date($0["last_edited_time"]).map(Calendar.current.isDateInToday) ?? false }.count
        return ServiceDetail(pillId: "integration_notion",
                             stats: [DetailStat(label: "Edited today", value: "\(editedToday)", tone: editedToday > 0 ? .info : .idle),
                                     DetailStat(label: "Pages", value: "\(pages.count)"),
                                     DetailStat(label: "Databases", value: "\(databases.count)")],
                             sections: sections, fetchedAt: Date())
    }

    // MARK: Acting

    /// Runs one action. Returns a short line for the iPhone.
    static func perform(kind: String, target: String) async throws -> String {
        switch kind {
        case "vercel.redeploy":
            let parts = target.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { throw Failure(status: 0, message: "Unknown deployment") }
            var body: [String: Any] = ["name": parts[1], "deploymentId": parts[0]]
            if !parts[2].isEmpty { body["target"] = parts[2] }
            let json = try await request(VercelAPI.url("https://api.vercel.com/v13/deployments"), method: "POST",
                                         headers: try vercelHeaders(), body: body)
            let url = (json as? [String: Any])?["url"] as? String
            return url.map { "Building \($0)" } ?? "New deployment started"
        case "vercel.promote":
            // Vercel only promotes production builds in place: a preview is rebuilt for
            // production, as `vercel promote` does.
            let parts = target.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { throw Failure(status: 0, message: "Unknown deployment") }
            let json = try await request(VercelAPI.url("https://api.vercel.com/v13/deployments"), method: "POST",
                                         headers: try vercelHeaders(),
                                         body: ["deploymentId": parts[0], "name": parts[1], "target": "production",
                                                "meta": ["action": "promote"]])
            let url = (json as? [String: Any])?["url"] as? String
            return url.map { "Building \($0) for production" } ?? "Production build started"
        case "vercel.cancel":
            _ = try await request(VercelAPI.url("https://api.vercel.com/v12/deployments/\(target)/cancel"), method: "PATCH",
                                  headers: try vercelHeaders())
            return "Build canceled"
        case "github.rerun":
            // "owner/repo/123"
            let parts = target.split(separator: "/").map(String.init)
            guard parts.count == 3 else { throw Failure(status: 0, message: "Unknown run") }
            _ = try await request("https://api.github.com/repos/\(parts[0])/\(parts[1])/actions/runs/\(parts[2])/rerun-failed-jobs",
                                  method: "POST", headers: try githubHeaders())
            return "Failed jobs started again"
        case "github.approve", "github.merge":
            // "owner/repo#12"
            let pieces = target.split(separator: "#").map(String.init)
            guard pieces.count == 2 else { throw Failure(status: 0, message: "Unknown pull request") }
            if kind == "github.approve" {
                _ = try await request("https://api.github.com/repos/\(pieces[0])/pulls/\(pieces[1])/reviews", method: "POST",
                                      headers: try githubHeaders(), body: ["event": "APPROVE"])
                return "Approved"
            }
            _ = try await request("https://api.github.com/repos/\(pieces[0])/pulls/\(pieces[1])/merge", method: "PUT",
                                  headers: try githubHeaders(), body: ["merge_method": "squash"])
            return "Merged"
        case "n8n.activate", "n8n.deactivate", "n8n.retry":
            let key = try secret("n8n-api-key", "n8n")
            let base = try secret("n8n-url", "n8n").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let headers = ["X-N8N-API-KEY": key, "Accept": "application/json"]
            switch kind {
            case "n8n.activate":
                _ = try await request("\(base)/api/v1/workflows/\(target)/activate", method: "POST", headers: headers)
                return "Turned on"
            case "n8n.deactivate":
                _ = try await request("\(base)/api/v1/workflows/\(target)/deactivate", method: "POST", headers: headers)
                return "Turned off"
            default:
                do {
                    _ = try await request("\(base)/api/v1/executions/\(target)/retry", method: "POST", headers: headers)
                } catch let failure as Failure where failure.status == 404 || failure.status == 405 {
                    // POST /api/v1/executions/{id}/retry only exists from n8n 1.112.0.
                    throw Failure(status: 0, message: "Couldn't retry this run. It may have been deleted, or your n8n is older than 1.112, which is needed to retry from the iPhone.")
                }
                return "Running again"
            }
        default:
            throw Failure(status: 0, message: "This action isn't available")
        }
    }

    private static func vercelHeaders() throws -> [String: String] {
        let token = try secret("vercel-token", "Vercel")
        return ["Authorization": "Bearer \(token)", "Accept": "application/json"]
    }

    private static func githubHeaders() throws -> [String: String] {
        let token = try secret("github-token", "GitHub")
        return ["Authorization": "Bearer \(token)", "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28"]
    }
}
#endif
