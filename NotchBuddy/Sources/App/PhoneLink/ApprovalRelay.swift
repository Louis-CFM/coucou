#if PHONE_LINK
import AppKit
import CloudKit
import Combine
import CryptoKit

// MARK: - iPhone plan, step 7: approve or deny from the iPhone
//
// While Claude Code (or Cursor, Codex) waits for a permission:
//  1. an `ApprovalRequest` record goes to iCloud; the iPhone's query subscription
//     turns it into a notification;
//  2. the Mac looks for a `Decision` record every 2 s — only while a request is
//     pending, so nothing runs at rest;
//  3. a decision is applied only if its fingerprint matches the request still
//     pending (same session, tool, command and input). A late decision, or one
//     meant for another command, is ignored. Only "allow" and "deny" exist: no
//     "always" from the phone.
// The request record is deleted as soon as the approval is resolved, on either side.
//
// When the Live Activity is running and the LA push reached the iPhone (HTTP 200),
// the LA update is the alert (banner + sound + Allow/Deny on the Lock Screen). In
// that case the iCloud record is not written — it would add a second banner. If
// the LA push fails (relay down, no token), iCloud is used as before.
// The user can override this with the "always" notification setting (SettingsView).

@MainActor
final class ApprovalRelay {
    static let shared = ApprovalRelay()

    /// When true, the iCloud alert is sent even if the Live Activity already alerted.
    static let approvalAlwaysNotifyKey = "approvalAlwaysNotify"

    private let container = CKContainer(identifier: "iCloud.fr.louisraille.Coucou")
    private var database: CKDatabase { container.privateCloudDatabase }
    private var zoneID: CKRecordZone.ID { SessionSnapshot.zoneID }

    private var cancellable: AnyCancellable?
    private var current: (fingerprint: String, since: Date)?
    private var pollTask: Task<Void, Never>?
    private var changeToken: CKServerChangeToken?
    /// iCloud fallback: published after a delay if the Live Activity push didn't fire first.
    private var iCloudFallbackTask: Task<Void, Never>?
    /// When each fingerprint was first notified (across any channel), for the 2-min cooldown.
    private var recentlyNotified: [String: Date] = [:]

    /// Stable identifier of one pending request.
    nonisolated static func fingerprint(_ approval: ApprovalInfo) -> String {
        let raw = [approval.pillId, approval.sessionId, approval.tool, approval.command, approval.inputKey]
            .joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func start() {
        guard cancellable == nil else { return }
        // @Published sends the new value before the property changes, so the
        // value is passed along rather than read back from AppState.
        cancellable = AppState.shared.$pendingApproval
            .removeDuplicates { $0.map(Self.fingerprint) == $1.map(Self.fingerprint) }
            .sink { [weak self] approval in
                MainActor.assumeIsolated { self?.pendingChanged(to: approval) }
            }
        log("relay on")
    }

    func stop() {
        cancellable = nil
        iCloudFallbackTask?.cancel()
        iCloudFallbackTask = nil
        pendingChanged(to: nil)
    }

    // MARK: Request lifecycle

    private func pendingChanged(to approval: ApprovalInfo?) {
        // Never publish demo approval cards to iCloud
        if approval?.sessionId == "demo_session" { return }
        let fingerprint = approval.map(Self.fingerprint)
        if let old = current, old.fingerprint != fingerprint {
            pollTask?.cancel()
            pollTask = nil
            iCloudFallbackTask?.cancel()
            iCloudFallbackTask = nil
            current = nil
            let id = requestID(old.fingerprint)
            Task { _ = try? await database.modifyRecords(saving: [], deleting: [id]) }
        }
        guard let fingerprint, let approval, current?.fingerprint != fingerprint else { return }
        current = (fingerprint, Date())

        // Decision polling — always, regardless of which channel handles the notification.
        pollTask = Task { [weak self] in
            // The Mac dismisses the request after 115 s anyway.
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                if await self.checkDecisions(for: fingerprint) { return }
            }
        }

        // 2-minute cooldown: same fingerprint (Claude retries the same command) doesn't ring again.
        let now = Date()
        recentlyNotified = recentlyNotified.filter { now.timeIntervalSince($0.value) < 180 }
        if let first = recentlyNotified[fingerprint], now.timeIntervalSince(first) < 120 {
            log("approval (\(approval.tool)): within 2-min cooldown, polling only")
            return
        }
        recentlyNotified[fingerprint] = now

        // When the Live Activity is active, let it be the alert (it shows Allow/Deny and
        // plays approval.wav right on the Lock Screen). The LA relay calls
        // liveActivityHandledApproval() if the push goes through; otherwise the fallback
        // below publishes the iCloud record and the query subscription delivers the banner.
        let laActive = LiveActivityRelay.isEnabled && LiveActivityRelay.shared.startedAt != nil
        let alwaysNotify = UserDefaults.standard.bool(forKey: Self.approvalAlwaysNotifyKey)
        if laActive && !alwaysNotify {
            // Give the LA relay time to push (1 s debounce + network ≈ 5 s; 20 s to be safe).
            iCloudFallbackTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, let self else { return }
                await self.publishRequest(approval, fingerprint: fingerprint)
            }
            log("approval (\(approval.tool)): LA active, waiting for relay before iCloud")
        } else {
            Task { await publishRequest(approval, fingerprint: fingerprint) }
        }
    }

    /// Called by `LiveActivityRelay` when its urgent push reached the iPhone (HTTP 200).
    /// Cancels the iCloud fallback so only one alert is delivered.
    func liveActivityHandledApproval(_ fingerprint: String) {
        guard current?.fingerprint == fingerprint else { return }
        iCloudFallbackTask?.cancel()
        iCloudFallbackTask = nil
        log("approval (\(fingerprint.prefix(8))…): LA delivered, iCloud record skipped")
    }

    /// Called by `LiveActivityRelay` when every push attempt failed (relay unreachable, 4xx/5xx,
    /// bad token). Cancels the 20 s wait and publishes to iCloud right away so the user gets
    /// notified without the full delay.
    func liveActivityFailedApproval(_ fingerprint: String) {
        guard current?.fingerprint == fingerprint else { return }
        iCloudFallbackTask?.cancel()
        iCloudFallbackTask = nil
        guard let approval = AppState.shared.pendingApproval,
              Self.fingerprint(approval) == fingerprint else { return }
        Task { [weak self] in await self?.publishRequest(approval, fingerprint: fingerprint) }
        log("approval (\(fingerprint.prefix(8))…): LA push failed, iCloud notified immediately")
    }

    private func requestID(_ fingerprint: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "approval-\(fingerprint.prefix(32))", zoneID: zoneID)
    }

    private func publishRequest(_ approval: ApprovalInfo, fingerprint: String) async {
        let record = CKRecord(recordType: "ApprovalRequest", recordID: requestID(fingerprint))
        record["pillId"] = approval.pillId
        record["fingerprint"] = fingerprint
        record["createdAt"] = Date()
        record.encryptedValues["tool"] = approval.tool
        record.encryptedValues["command"] = approval.command
        do {
            _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
            log("approval request sent to the iPhone (\(approval.tool))")
        } catch {
            log("approval request failed: \(error.localizedDescription)")
        }
    }

    // MARK: Decisions

    /// Returns true once a matching decision was applied.
    private func checkDecisions(for fingerprint: String) async -> Bool {
        guard current?.fingerprint == fingerprint, let since = current?.since else { return true }
        var found: [(CKRecord.ID, String, String)] = []   // id, fingerprint, decision
        do {
            var more = true
            while more {
                let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: changeToken)
                for (id, result) in changes.modificationResultsByID {
                    guard case .success(let mod) = result, mod.record.recordType == "Decision" else { continue }
                    let record = mod.record
                    let decidedAt = record["decidedAt"] as? Date ?? .distantPast
                    guard decidedAt >= since.addingTimeInterval(-5) else { continue }
                    found.append((id, record["fingerprint"] as? String ?? "", record["decision"] as? String ?? ""))
                }
                changeToken = changes.changeToken
                more = changes.moreComing
            }
        } catch let error as CKError where error.code == .changeTokenExpired {
            changeToken = nil
            return false
        } catch {
            // The request was settled on the Mac meanwhile: its poll is cancelled, not failed.
            if Task.isCancelled || (error as? CKError)?.code == .operationCancelled { return true }
            log("decision check failed: \(error.localizedDescription)")
            return false
        }
        guard !found.isEmpty else { return false }
        // Decisions are single use.
        let ids = found.map(\.0)
        Task { _ = try? await database.modifyRecords(saving: [], deleting: ids) }

        guard let match = found.first(where: { $0.1 == fingerprint }) else {
            log("ignored \(found.count) decision(s) for another request")
            return false
        }
        apply(match.2, fingerprint: fingerprint)
        return true
    }

    private func apply(_ decision: String, fingerprint: String) {
        // Check again on the main actor, right before answering the hook.
        guard let pending = AppState.shared.pendingApproval,
              Self.fingerprint(pending) == fingerprint else {
            log("decision arrived after the request was resolved, ignored")
            return
        }
        switch decision {
        case "allow":
            log("allowed from the iPhone: \(pending.tool)")
            HookServer.shared.sendApprovalDecision("allow", for: pending.id)
        case "deny":
            log("denied from the iPhone: \(pending.tool)")
            HookServer.shared.sendApprovalDecision("deny", for: pending.id)
        default:
            log("unknown decision '\(decision)', ignored")
        }
    }

    private func log(_ message: String) {
        CloudProbe.shared.log("[approval] \(message)")
    }
}
#endif
