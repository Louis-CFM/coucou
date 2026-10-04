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

@MainActor
final class ApprovalRelay {
    static let shared = ApprovalRelay()

    private let container = CKContainer(identifier: "iCloud.fr.louisraille.Coucou")
    private var database: CKDatabase { container.privateCloudDatabase }
    private var zoneID: CKRecordZone.ID { SessionSnapshot.zoneID }

    private var cancellable: AnyCancellable?
    private var current: (fingerprint: String, since: Date)?
    private var pollTask: Task<Void, Never>?
    private var changeToken: CKServerChangeToken?

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
        pendingChanged(to: nil)
    }

    // MARK: Request lifecycle

    private func pendingChanged(to approval: ApprovalInfo?) {
        let fingerprint = approval.map(Self.fingerprint)
        if let old = current, old.fingerprint != fingerprint {
            pollTask?.cancel()
            pollTask = nil
            current = nil
            let id = requestID(old.fingerprint)
            Task { _ = try? await database.modifyRecords(saving: [], deleting: [id]) }
        }
        guard let fingerprint, let approval, current?.fingerprint != fingerprint else { return }
        current = (fingerprint, Date())
        Task { await publishRequest(approval, fingerprint: fingerprint) }
        pollTask = Task { [weak self] in
            // The Mac dismisses the request after 115 s anyway.
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                if await self.checkDecisions(for: fingerprint) { return }
            }
        }
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
            HookServer.shared.sendApprovalDecision("allow")
        case "deny":
            log("denied from the iPhone: \(pending.tool)")
            HookServer.shared.sendApprovalDecision("deny")
        default:
            log("unknown decision '\(decision)', ignored")
        }
    }

    private func log(_ message: String) {
        CloudProbe.shared.log("[approval] \(message)")
    }
}
#endif
