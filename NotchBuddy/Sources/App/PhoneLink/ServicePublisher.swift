#if PHONE_LINK
import AppKit
import CloudKit
import Combine

// MARK: - Services on the iPhone
//
// One `Service` record per service Mochi (GitHub, Stripe, Vercel, Resend,
// Cal.com, n8n, Notion), built from the data the Mac's pollers already keep in
// AppState: no extra API call, no key sent anywhere. The whole snapshot
// (amounts, titles, emails, links) is one field encrypted with the user's
// iCloud keys; only the pill ID, the state dot and the date are in clear.
// Driven by AppState changes (debounced), never by a timer.

@MainActor
final class ServicePublisher {
    static let shared = ServicePublisher()

    private let container = CKContainer(identifier: CloudProbe.containerID)
    private var database: CKDatabase { container.privateCloudDatabase }
    private var cancellable: AnyCancellable?
    private var published: [String: ServiceSnapshot] = [:]
    private var cleanedUp = false
    private var writing = false
    private var again = false

    func start() {
        guard cancellable == nil else { return }
        let s = AppState.shared
        let changes: [AnyPublisher<Void, Never>] = [
            s.$stripePayments.map { _ in () }.eraseToAnyPublisher(),
            s.$stripeBalance.map { _ in () }.eraseToAnyPublisher(),
            s.$stripeError.map { _ in () }.eraseToAnyPublisher(),
            s.$githubPulse.map { _ in () }.eraseToAnyPublisher(),
            s.$githubActivity.map { _ in () }.eraseToAnyPublisher(),
            s.$vercelDeployments.map { _ in () }.eraseToAnyPublisher(),
            s.$resendEmails.map { _ in () }.eraseToAnyPublisher(),
            s.$calcomBookings.map { _ in () }.eraseToAnyPublisher(),
            s.$calcomError.map { _ in () }.eraseToAnyPublisher(),
            s.$notionPages.map { _ in () }.eraseToAnyPublisher(),
            s.$notionError.map { _ in () }.eraseToAnyPublisher(),
            s.$n8nRuns.map { _ in () }.eraseToAnyPublisher(),
        ]
        cancellable = Publishers.MergeMany(changes)
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.publish() }
            }
        log("service publisher on")
    }

    /// Stops and deletes this Mac's services from iCloud.
    func stop() {
        cancellable = nil
        let ids = PillCatalog.phoneServices.map {
            CKRecord.ID(recordName: ServiceSnapshot.recordName(for: $0), zoneID: SessionSnapshot.zoneID)
        }
        published = [:]
        cleanedUp = false
        Task { _ = try? await database.modifyRecords(saving: [], deleting: ids, savePolicy: .changedKeys, atomically: false) }
        log("service publisher off")
    }

    private func publish() {
        guard !writing else { again = true; return }
        writing = true
        let snapshots = ServiceSnapshots.all(from: AppState.shared)
        Task {
            await write(snapshots)
            writing = false
            if again { again = false; publish() }
        }
    }

    private func write(_ snapshots: [String: ServiceSnapshot]) async {
        var deletions: [CKRecord.ID] = []
        if !cleanedUp {
            // Services this Mac no longer has (key removed since the last run).
            deletions = PillCatalog.phoneServices.filter { snapshots[$0] == nil }.map {
                CKRecord.ID(recordName: ServiceSnapshot.recordName(for: $0), zoneID: SessionSnapshot.zoneID)
            }
            cleanedUp = true
        }
        let changed = snapshots.values.filter { snapshot in
            guard let old = published[snapshot.pillId] else { return true }
            return !old.sameContent(as: snapshot)
        }
        let removed = published.keys.filter { snapshots[$0] == nil }
        deletions += removed.map { CKRecord.ID(recordName: ServiceSnapshot.recordName(for: $0), zoneID: SessionSnapshot.zoneID) }
        guard !changed.isEmpty || !deletions.isEmpty else { return }

        let records = changed.compactMap { record(for: $0) }
        do {
            let result = try await database.modifyRecords(saving: records, deleting: deletions,
                                                          savePolicy: .changedKeys, atomically: false)
            for (id, outcome) in result.saveResults {
                guard let pillId = ServiceSnapshot.pillId(fromRecordName: id.recordName) else { continue }
                if case .success = outcome { published[pillId] = snapshots[pillId] }
            }
            for id in removed { published[id] = nil }
            let names = changed.map { "\($0.pillId.replacingOccurrences(of: "integration_", with: ""))=\($0.tone.rawValue)" }
            log("published \(changed.count) service(s) [\(names.sorted().joined(separator: ", "))], removed \(deletions.count)")
        } catch {
            log("publish failed: \(error.localizedDescription)")
        }
    }

    private func record(for snapshot: ServiceSnapshot) -> CKRecord? {
        guard let json = try? JSONEncoder().encode(snapshot), let payload = String(data: json, encoding: .utf8) else { return nil }
        let record = CKRecord(recordType: ServiceSnapshot.recordType,
                              recordID: CKRecord.ID(recordName: ServiceSnapshot.recordName(for: snapshot.pillId),
                                                    zoneID: SessionSnapshot.zoneID))
        record["pillId"] = snapshot.pillId
        record["tone"] = snapshot.tone.rawValue
        record["updatedAt"] = snapshot.updatedAt
        record["macName"] = Host.current().localizedName ?? ""
        record.encryptedValues["payload"] = payload
        return record
    }

    private func log(_ message: String) {
        CloudProbe.shared.log("[services] \(message)")
    }
}

// MARK: - Building the snapshots

/// One snapshot per service that has data on this Mac. A service without its
/// key (nothing loaded) is left out, and the iPhone shows "connect it on your Mac".
@MainActor
enum ServiceSnapshots {
    static func all(from s: AppState) -> [String: ServiceSnapshot] {
        let built = [github(s), stripe(s), vercel(s), resend(s), calcom(s), n8n(s), notion(s)].compactMap { $0 }
        return Dictionary(uniqueKeysWithValues: built.map { ($0.pillId, $0) })
    }

    // MARK: GitHub

    static func github(_ s: AppState) -> ServiceSnapshot? {
        guard let pulse = s.githubPulse else { return nil }
        func tone(_ ci: CIState) -> ServiceTone {
            switch ci {
            case .success: .ok
            case .failure: .error
            case .pending: .warning
            case .unknown: .idle
            }
        }
        func ciLabel(_ ci: CIState) -> String {
            switch ci {
            case .success: "checks passed"
            case .failure: "checks failing"
            case .pending: "checks running"
            case .unknown: "no checks"
            }
        }
        func reviewLabel(_ review: ReviewState) -> String {
            switch review {
            case .approved: " · approved"
            case .changesRequested: " · changes requested"
            case .pending: " · review required"
            case .unknown: ""
            }
        }
        let failingPR = pulse.myPRs.first { $0.ci == .failure }
        let failingMain = pulse.mainCI.first { $0.ci == .failure }
        let pending = pulse.myPRs.contains { $0.ci == .pending } || pulse.mainCI.contains { $0.ci == .pending }
        let anyGreen = pulse.myPRs.contains { $0.ci == .success } || pulse.mainCI.contains { $0.ci == .success }

        let overall: ServiceTone
        let reason: String
        if let main = failingMain {
            overall = .error
            reason = "CI failing on \(main.repo) · \(main.branch)"
        } else if let pr = failingPR {
            overall = .error
            reason = "Checks failing on \(pr.repo) #\(pr.number): \(pr.title)"
        } else if pending {
            overall = .warning
            reason = "Checks are running"
        } else if !pulse.toReview.isEmpty {
            overall = .warning
            reason = pulse.toReview.count == 1
                ? "1 pull request waits for your review"
                : "\(pulse.toReview.count) pull requests wait for your review"
        } else if anyGreen {
            overall = .ok
            reason = "All checks passed"
        } else {
            overall = .idle
            reason = "Nothing going on"
        }

        var sections: [ServiceSection] = []
        if !pulse.myPRs.isEmpty {
            sections.append(ServiceSection(title: "Your pull requests", items: pulse.myPRs.prefix(8).map {
                ServiceItem(title: "#\($0.number) \($0.title)",
                            detail: "\($0.repo) · \(ciLabel($0.ci))\(reviewLabel($0.review))\($0.isDraft ? " · draft" : "")",
                            tone: tone($0.ci), url: $0.url)
            }))
        }
        if !pulse.toReview.isEmpty {
            sections.append(ServiceSection(title: "Waiting for your review", items: pulse.toReview.prefix(8).map {
                ServiceItem(title: "#\($0.number) \($0.title)", detail: $0.repo, tone: .warning, url: $0.url)
            }))
        }
        if !pulse.mainCI.isEmpty {
            sections.append(ServiceSection(title: "Default branches", items: pulse.mainCI.prefix(8).map {
                ServiceItem(title: $0.repo, detail: "\($0.branch) · \(ciLabel($0.ci))", tone: tone($0.ci), url: $0.url)
            }))
        }
        var headline = "\(pulse.myPRs.count) open pull request\(pulse.myPRs.count == 1 ? "" : "s")"
        if let total = s.githubActivity?.total { headline += " · \(total) contributions this year" }
        return ServiceSnapshot(pillId: "integration_github", tone: overall, headline: headline, reason: reason,
                               sections: sections, updatedAt: pulse.fetchedAt)
    }

    // MARK: Stripe

    static func stripe(_ s: AppState) -> ServiceSnapshot? {
        if let error = s.stripeError, !s.stripeLoaded {
            return ServiceSnapshot(pillId: "integration_stripe", tone: .error, headline: "Can't reach Stripe",
                                   reason: error, sections: [], updatedAt: Date())
        }
        guard s.stripeLoaded else { return nil }
        let currency = s.stripeCurrency.uppercased()
        func money(_ cents: Int, _ code: String) -> String {
            String(format: "%.2f %@", Double(cents) / 100, code.uppercased())
        }
        let latest = s.stripePayments.first
        let overall: ServiceTone
        let reason: String
        if let error = s.stripeError {
            overall = .error
            reason = "Stripe answered with an error: \(error)"
        } else if let latest {
            let what = latest.description.map { " · \($0)" } ?? ""
            switch latest.status {
            case "succeeded":
                overall = Date().timeIntervalSince(latest.createdAt) < 86_400 ? .ok : .idle
                reason = "Last payment received: \(money(latest.amount, latest.currency))\(what)"
            case "failed":
                overall = .error
                reason = "Last payment failed: \(money(latest.amount, latest.currency))\(what)"
            default:
                overall = .warning
                reason = "Last payment pending: \(money(latest.amount, latest.currency))\(what)"
            }
        } else {
            overall = .idle
            reason = "No payment yet"
        }
        let items = s.stripePayments.prefix(10).map {
            ServiceItem(title: money($0.amount, $0.currency),
                        detail: [$0.description, $0.status].compactMap { $0 }.joined(separator: " · "),
                        tone: $0.isSuccess ? .ok : ($0.status == "failed" ? .error : .warning),
                        date: $0.createdAt)
        }
        return ServiceSnapshot(pillId: "integration_stripe", tone: overall,
                               headline: "Balance \(money(s.stripeBalance, currency))", reason: reason,
                               sections: items.isEmpty ? [] : [ServiceSection(title: "Recent payments", items: items)],
                               updatedAt: latest?.createdAt ?? Date())
    }

    // MARK: Vercel

    static func vercel(_ s: AppState) -> ServiceSnapshot? {
        let filter = s.vercelProjectFilter
        let deployments = filter.isEmpty ? s.vercelDeployments : s.vercelDeployments.filter { filter.contains($0.projectName) }
        guard let latest = deployments.first else { return nil }
        func tone(_ d: VercelDeployment) -> ServiceTone {
            d.isSuccess ? .ok : (d.state == "CANCELED" ? .warning : .error)
        }
        let branch = latest.branch.map { " · \($0)" } ?? ""
        let reason: String
        switch latest.state {
        case "READY": reason = "Last deploy is live: \(latest.projectName)\(branch)"
        case "CANCELED": reason = "Last deploy was canceled: \(latest.projectName)\(branch)"
        default: reason = "Last deploy failed: \(latest.projectName)\(branch)"
        }
        let items = deployments.prefix(10).map { d in
            ServiceItem(title: d.projectName,
                        detail: [d.statusLabel, d.branch, d.commitMessage].compactMap { $0 }.joined(separator: " · "),
                        tone: tone(d), date: d.createdAt,
                        url: d.url.isEmpty ? nil : "https://\(d.url)")
        }
        return ServiceSnapshot(pillId: "integration_vercel", tone: tone(latest),
                               headline: "\(latest.projectName) · \(latest.statusLabel)", reason: reason,
                               sections: [ServiceSection(title: "Deployments", items: items)],
                               updatedAt: latest.createdAt)
    }

    // MARK: Resend

    static func resend(_ s: AppState) -> ServiceSnapshot? {
        guard let latest = s.resendEmails.first else { return nil }
        func tone(_ event: String) -> ServiceTone {
            switch event {
            case "bounced", "complained", "failed": .error
            case "delivered", "opened", "clicked": .ok
            case "delivery_delayed": .warning
            default: .info
            }
        }
        let reason: String
        switch tone(latest.lastEvent) {
        case .error: reason = "Last email \(latest.lastEvent): \(latest.subject)"
        case .warning: reason = "Last email is delayed: \(latest.subject)"
        case .ok: reason = "Last email \(latest.lastEvent): \(latest.subject)"
        default: reason = "Last email \(latest.lastEvent): \(latest.subject)"
        }
        let items = s.resendEmails.prefix(10).map {
            ServiceItem(title: $0.subject, detail: "to \($0.to.joined(separator: ", ")) · \($0.lastEvent)",
                        tone: tone($0.lastEvent), date: $0.createdAt)
        }
        let total = s.resendTotal.map { "\($0) emails sent" } ?? "Emails"
        return ServiceSnapshot(pillId: "integration_resend", tone: tone(latest.lastEvent), headline: total,
                               reason: reason, sections: [ServiceSection(title: "Recent emails", items: items)],
                               updatedAt: latest.createdAt)
    }

    // MARK: Cal.com

    static func calcom(_ s: AppState) -> ServiceSnapshot? {
        if let error = s.calcomError, !s.calcomLoaded {
            return ServiceSnapshot(pillId: "integration_calcom", tone: .error, headline: "Can't reach Cal.com",
                                   reason: error, sections: [], updatedAt: Date())
        }
        guard s.calcomLoaded else { return nil }
        let upcoming = s.calcomBookings.filter { $0.endTime > Date() }.sorted { $0.startTime < $1.startTime }
        let next = upcoming.first { $0.isActive }
        let time = Date.FormatStyle(date: .abbreviated, time: .shortened)
        let overall: ServiceTone
        let reason: String
        if let next {
            let soon = next.startTime.timeIntervalSinceNow < 3600
            overall = soon ? .warning : .info
            let with = next.attendeeName.map { " with \($0)" } ?? ""
            reason = "\(soon ? "Starting soon" : "Next"): \(next.title)\(with), \(next.startTime.formatted(time))"
        } else {
            overall = .idle
            reason = "No upcoming booking"
        }
        let items = upcoming.prefix(10).map {
            ServiceItem(title: $0.title,
                        detail: [$0.attendeeName, $0.status.lowercased()].compactMap { $0 }.joined(separator: " · "),
                        tone: $0.isActive ? .info : .idle, date: $0.startTime)
        }
        let count = upcoming.filter(\.isActive).count
        return ServiceSnapshot(pillId: "integration_calcom", tone: overall,
                               headline: "\(count) upcoming booking\(count == 1 ? "" : "s")", reason: reason,
                               sections: items.isEmpty ? [] : [ServiceSection(title: "Upcoming", items: items)],
                               updatedAt: Date())
    }

    // MARK: n8n

    static func n8n(_ s: AppState) -> ServiceSnapshot? {
        guard let latest = s.n8nRuns.first else { return nil }
        let reason = latest.success
            ? "Last run succeeded: \(latest.workflow)"
            : "Last run failed: \(latest.workflow)\(latest.detail.map { " · \($0)" } ?? "")"
        let items = s.n8nRuns.map {
            ServiceItem(title: $0.workflow, detail: $0.detail ?? ($0.success ? "succeeded" : "failed"),
                        tone: $0.success ? .ok : .error, date: $0.date)
        }
        let failed = s.n8nRuns.filter { !$0.success }.count
        return ServiceSnapshot(pillId: "integration_n8n", tone: latest.success ? .ok : .error,
                               headline: failed == 0 ? "All recent runs succeeded" : "\(failed) failed run\(failed == 1 ? "" : "s")",
                               reason: reason, sections: [ServiceSection(title: "Recent runs", items: items)],
                               updatedAt: latest.date)
    }

    // MARK: Notion

    static func notion(_ s: AppState) -> ServiceSnapshot? {
        if let error = s.notionError, !s.notionLoaded {
            return ServiceSnapshot(pillId: "integration_notion", tone: .error, headline: "Can't reach Notion",
                                   reason: error, sections: [], updatedAt: Date())
        }
        guard s.notionLoaded else { return nil }
        let pages = s.notionPages.sorted { $0.lastEditedAt > $1.lastEditedAt }
        let items = pages.prefix(10).map {
            ServiceItem(title: [$0.emoji, $0.title].compactMap { $0 }.joined(separator: " "),
                        tone: .info, date: $0.lastEditedAt, url: $0.url)
        }
        let reason = pages.first.map { "Last edited: \($0.title)" } ?? "No recent page"
        let recent = (pages.first?.lastEditedAt.timeIntervalSinceNow ?? -.infinity) > -3600
        return ServiceSnapshot(pillId: "integration_notion", tone: recent ? .info : .idle,
                               headline: "\(pages.count) recent page\(pages.count == 1 ? "" : "s")", reason: reason,
                               sections: items.isEmpty ? [] : [ServiceSection(title: "Recently edited", items: items)],
                               updatedAt: pages.first?.lastEditedAt ?? Date())
    }
}
#endif
