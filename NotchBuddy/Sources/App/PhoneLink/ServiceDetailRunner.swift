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

#endif
