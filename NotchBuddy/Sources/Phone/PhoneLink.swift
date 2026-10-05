import CloudKit
import Observation
import UIKit
import UserNotifications
import WidgetKit

/// A Ping written by the Mac, as seen by the iPhone.
struct PingItem: Identifiable {
    let id: CKRecord.ID
    let macName: String
    let app: String
    let message: String
    let sentAt: Date
    /// When this iPhone first saw it. nil for pings that were already there at launch.
    let receivedAt: Date?
    var delay: TimeInterval? { receivedAt.map { $0.timeIntervalSince(sentAt) } }
}

/// An agent session published by the Mac (SessionPublisher), as seen by the iPhone.
struct SessionItem: Identifiable {
    let id: String          // pill ID
    let name: String
    let color: String
    let state: BotState
    let stepIndex: Int
    let steps: [String]
    let needsApproval: Bool
    let approvalCommand: String
    let approvalFingerprint: String
    let question: String
    let finalLine: String
    let cwd: String
    let updatedAt: Date
    let macName: String

    init(record: CKRecord) {
        id = record["pillId"] as? String ?? record.recordID.recordName
        name = record.encryptedValues["name"] as? String ?? ""
        color = record["color"] as? String ?? "#C0C4CC"
        state = BotState(rawValue: record["state"] as? String ?? "") ?? .idle
        stepIndex = record["stepIndex"] as? Int ?? 0
        steps = record.encryptedValues["steps"] as? [String] ?? []
        needsApproval = record["needsApproval"] as? Bool ?? false
        approvalCommand = record.encryptedValues["approvalCommand"] as? String ?? ""
        approvalFingerprint = record["approvalFingerprint"] as? String ?? ""
        question = record.encryptedValues["question"] as? String ?? ""
        finalLine = record.encryptedValues["finalLine"] as? String ?? ""
        cwd = record.encryptedValues["cwd"] as? String ?? ""
        updatedAt = record["updatedAt"] as? Date ?? record.modificationDate ?? .now
        macName = record["macName"] as? String ?? ""
    }

    var pillName: String { PillCatalog.definition(for: id)?.name ?? id }
    var currentStep: String? { steps.indices.contains(stepIndex) ? steps[stepIndex] : steps.last }
}

@MainActor
@Observable
final class PhoneLink {
    static let shared = PhoneLink()

    enum Status: Equatable {
        case starting
        case noAccount(String)
        case zoneMissing
        case ready
        case failed(String)
    }

    static let containerID = "iCloud.fr.louisraille.Coucou"
    static let zoneID = CKRecordZone.ID(zoneName: "Coucou", ownerName: CKCurrentUserDefaultName)
    private static let subscriptionID = "coucou-zone-phone-silent"
    /// Step 1's subscription showed a "Ping from your Mac" banner. A saved
    /// subscription keeps its notification settings, so it is deleted rather than reused.
    private static let oldSubscriptionID = "coucou-zone-phone"

    var status: Status = .starting
    var pings: [PingItem] = []
    var sessions: [SessionItem] = []
    /// Service Mochi (GitHub, Stripe…) the Mac publishes, by pill ID.
    var services: [String: ServiceSnapshot] = [:]
    var lastPong: String?
    var pushError: String?
    var notificationsAllowed: Bool?

    @ObservationIgnored private let container = CKContainer(identifier: PhoneLink.containerID)
    @ObservationIgnored private var database: CKDatabase { container.privateCloudDatabase }
    @ObservationIgnored private var changeToken: CKServerChangeToken?
    @ObservationIgnored private var firstFetchDone = false
    @ObservationIgnored private var subscribed = false
    @ObservationIgnored private var approvalsSubscribed = false
    @ObservationIgnored private var fetching = false

    func start() async {
        let center = UNUserNotificationCenter.current()
        notificationsAllowed = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refresh()
    }

    /// Checks the account, makes sure the subscription exists, then fetches new records.
    func refresh() async {
        do {
            let accountStatus = try await container.accountStatus()
            guard accountStatus == .available else {
                status = .noAccount(describe(accountStatus))
                return
            }
        } catch {
            status = .noAccount(error.localizedDescription)
            return
        }
        if !subscribed { await subscribe() }
        if subscribed && !approvalsSubscribed { await subscribeToApprovals() }
        _ = await fetchChanges()
        await notifyNewApprovals()
    }

    /// Called on a CloudKit push. Returns true when new records arrived.
    func handlePush() async -> Bool {
        let gotNew = await fetchChanges()
        await notifyNewApprovals()
        return gotNew
    }

    private func subscribe() async {
        let sub = CKDatabaseSubscription(subscriptionID: Self.subscriptionID)
        // Silent: the Mac writes on every session change, a banner each time
        // would be noise. Approvals have their own subscription below.
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        sub.notificationInfo = info
        do {
            _ = try await database.modifySubscriptions(saving: [sub], deleting: [Self.oldSubscriptionID])
            subscribed = true
        } catch {
            status = .failed("Subscription: \(error.localizedDescription)")
        }
    }

    /// A visible notification for each approval request the Mac sends
    /// (ApprovalRelay), with Review and Deny actions. Kept apart from the
    /// silent subscription so a failure here never stops the sessions.
    private func subscribeToApprovals() async {
        let approvals = CKQuerySubscription(recordType: "ApprovalRequest", predicate: NSPredicate(value: true),
                                            subscriptionID: "coucou-approvals", options: [.firesOnRecordCreation])
        approvals.zoneID = Self.zoneID
        let alert = CKSubscription.NotificationInfo()
        alert.title = "Coucou"
        alert.alertBody = "An agent is waiting for your OK"
        alert.soundName = "default"
        alert.category = ApprovalActions.category
        alert.shouldSendContentAvailable = true
        alert.desiredKeys = ["fingerprint", "pillId"]
        approvals.notificationInfo = alert
        do {
            _ = try await database.modifySubscriptions(saving: [approvals], deleting: [])
            approvalsSubscribed = true
            approvalsStatus = "On"
        } catch {
            // In the Development environment a query subscription needs the
            // record type to exist: create it once with a throwaway record.
            let seed = CKRecord(recordType: "ApprovalRequest",
                                recordID: CKRecord.ID(recordName: "approval-schema", zoneID: Self.zoneID))
            seed["pillId"] = ""
            seed["fingerprint"] = ""
            seed["createdAt"] = Date()
            seed.encryptedValues["tool"] = ""
            seed.encryptedValues["command"] = ""
            do {
                _ = try await database.modifyRecords(saving: [seed], deleting: [], savePolicy: .allKeys)
                _ = try await database.modifyRecords(saving: [], deleting: [seed.recordID])
                _ = try await database.modifySubscriptions(saving: [approvals], deleting: [])
                approvalsSubscribed = true
                approvalsStatus = "On (record type created)"
            } catch {
                approvalsStatus = "Failed: \(error.localizedDescription)"
            }
        }
    }

    @discardableResult
    private func fetchChanges() async -> Bool {
        guard !fetching else { return false }
        fetching = true
        defer { fetching = false }
        var gotNew = false
        do {
            var more = true
            while more {
                let changes = try await database.recordZoneChanges(inZoneWith: Self.zoneID, since: changeToken)
                for (_, result) in changes.modificationResultsByID {
                    if case .success(let mod) = result, add(mod.record) { gotNew = true }
                }
                for deletion in changes.deletions where deletion.recordType == "Session" {
                    sessions.removeAll { "session-\($0.id)" == deletion.recordID.recordName }
                    gotNew = true
                }
                for deletion in changes.deletions where deletion.recordType == ServiceSnapshot.recordType {
                    if let id = ServiceSnapshot.pillId(fromRecordName: deletion.recordID.recordName) {
                        services[id] = nil
                        gotNew = true
                    }
                }
                changeToken = changes.changeToken
                more = changes.moreComing
            }
            firstFetchDone = true
            status = .ready
            if gotNew { updateWidgets() }
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            status = .zoneMissing
        } catch let error as CKError where error.code == .changeTokenExpired {
            changeToken = nil
        } catch let error as CKError where error.code == .notAuthenticated {
            status = .noAccount(error.localizedDescription)
        } catch {
            status = .failed(error.localizedDescription)
        }
        pings.sort { $0.sentAt > $1.sentAt }
        return gotNew
    }

    private func add(_ record: CKRecord) -> Bool {
        if record.recordType == ServiceSnapshot.recordType {
            guard let payload = record.encryptedValues["payload"] as? String,
                  let snapshot = try? JSONDecoder().decode(ServiceSnapshot.self, from: Data(payload.utf8)) else { return false }
            services[snapshot.pillId] = snapshot
            return true
        }
        if record.recordType == "Session" {
            let item = SessionItem(record: record)
            // Services used to come as sessions; they have their own records now.
            guard PillCatalog.isSession(item.id) else { return false }
            sessions.removeAll { $0.id == item.id }
            sessions.append(item)
            sessions.sort { $0.updatedAt > $1.updatedAt }
            return true
        }
        guard record.recordType == "Ping",
              !pings.contains(where: { $0.id == record.recordID }) else { return false }
        pings.append(PingItem(
            id: record.recordID,
            macName: record["macName"] as? String ?? "Mac",
            app: record["app"] as? String ?? "",
            message: record.encryptedValues["message"] as? String ?? "",
            sentAt: record["sentAt"] as? Date ?? record.creationDate ?? .now,
            receivedAt: firstFetchDone ? .now : nil
        ))
        return true
    }

    // MARK: Approval notifications (step 7)

    /// State of the "coucou-approvals" subscription, shown on the link test screen.
    var approvalsStatus = "Not set up yet"
    @ObservationIgnored private var notifiedFingerprints: Set<String> = []

    nonisolated static func approvalNotificationID(_ fingerprint: String) -> String { "approval-\(fingerprint)" }

    /// The iCloud alert for an approval doesn't always come. The silent push
    /// that updates the sessions does, so a new approval also gets a local
    /// notification, unless the iCloud one came, or the app is open.
    /// Notifications for requests no longer pending are removed.
    private func notifyNewApprovals() async {
        await removeAnsweredNotifications()
        let fresh = sessions.filter {
            $0.needsApproval && !$0.approvalFingerprint.isEmpty && !notifiedFingerprints.contains($0.approvalFingerprint)
        }
        guard !fresh.isEmpty else { return }
        fresh.forEach { notifiedFingerprints.insert($0.approvalFingerprint) }
        // The app is open: the request is on screen.
        guard UIApplication.shared.applicationState != .active else { return }
        // Give the iCloud alert a moment to land first, then check the request still waits.
        try? await Task.sleep(for: .seconds(3))
        _ = await fetchChanges()
        let shown = await Self.shownApprovals().map { $0.fingerprint }
        for session in fresh where !shown.contains(session.approvalFingerprint) {
            guard pendingFingerprints.contains(session.approvalFingerprint),
                  !iCloudAlerted.contains(session.approvalFingerprint) else { continue }
            let content = UNMutableNotificationContent()
            content.title = "\(session.pillName) · \(session.title)"
            content.body = session.approvalCommand.isEmpty
                ? "An agent is waiting for your OK"
                : "Waiting for your OK: \(session.approvalCommand.prefix(140))"
            content.sound = .default
            content.categoryIdentifier = ApprovalActions.category
            content.userInfo = ["fingerprint": session.approvalFingerprint, "pillId": session.id]
            let request = UNNotificationRequest(identifier: Self.approvalNotificationID(session.approvalFingerprint),
                                                content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    /// Fingerprints of the requests the Mac is still waiting on.
    private var pendingFingerprints: Set<String> {
        Set(sessions.filter(\.needsApproval).map(\.approvalFingerprint).filter { !$0.isEmpty })
    }

    /// Fingerprints whose iCloud alert reached this iPhone (shown or tapped).
    @ObservationIgnored private var iCloudAlerted: Set<String> = []

    func noteICloudAlert(_ fingerprint: String) {
        iCloudAlerted.insert(fingerprint)
        notifiedFingerprints.insert(fingerprint)
    }

    /// Clears the banners of requests answered on the Mac, on the iPhone or expired.
    private func removeAnsweredNotifications() async {
        let pending = pendingFingerprints
        let stale = await Self.shownApprovals().filter { !pending.contains($0.fingerprint) }.map { $0.id }
        if !stale.isEmpty { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: stale) }
    }

    /// Approval notifications in Notification Center, local or from iCloud.
    nonisolated static func shownApprovals() async -> [(id: String, fingerprint: String)] {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        return delivered.compactMap { notification in
            let request = notification.request
            return approvalFingerprint(in: request).map { (request.identifier, $0) }
        }
    }

    /// The approval fingerprint carried by a notification, local or from iCloud.
    nonisolated static func approvalFingerprint(in request: UNNotificationRequest) -> String? {
        let userInfo = request.content.userInfo
        if let fingerprint = userInfo["fingerprint"] as? String { return fingerprint }
        let note = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification
        return note?.recordFields?["fingerprint"] as? String
    }

    // MARK: Decisions (step 7)

    /// Decisions taken on this iPhone, newest first.
    var history: [DecisionLog] = DecisionLog.load()

    /// Set when the user taps "Review" on an approval notification.
    var reviewFingerprint: String?

    /// Sends allow / deny for one exact request. The Mac applies it only if the
    /// fingerprint still matches the request it is waiting on.
    func decide(_ decision: Decision, fingerprint: String, pillId: String, summary: String) async -> Bool {
        let record = CKRecord(recordType: "Decision",
                              recordID: CKRecord.ID(recordName: "decision-\(UUID().uuidString)", zoneID: Self.zoneID))
        record["fingerprint"] = fingerprint
        record["pillId"] = pillId
        record["decision"] = decision.rawValue
        record["decidedAt"] = Date()
        record["deviceName"] = UIDevice.current.name
        do {
            _ = try await database.save(record)
            history.insert(DecisionLog(decision: decision, pillId: pillId, summary: summary, date: .now), at: 0)
            history = Array(history.prefix(50))
            DecisionLog.save(history)
            return true
        } catch {
            lastPong = "Decision failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Hands the sessions to the widgets and asks them to redraw.
    private func updateWidgets() {
        SharedSessions.save(sessions.map(\.shared) + services.values.map(\.shared))
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Writes a Pong linked to the latest Ping.
    func sendPong() async {
        guard let ping = pings.first else { return }
        let record = CKRecord(recordType: "Pong",
                              recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: Self.zoneID))
        let repliedAt = Date()
        record["ping"] = CKRecord.Reference(recordID: ping.id, action: .none)
        record["pingSentAt"] = ping.sentAt
        record["repliedAt"] = repliedAt
        record["deviceName"] = UIDevice.current.name
        record.encryptedValues["message"] = "pong for \"\(ping.message)\""
        do {
            _ = try await database.save(record)
            lastPong = String(format: "Pong saved in %.1f s", Date().timeIntervalSince(repliedAt))
        } catch let error as CKError where error.code == .zoneNotFound {
            status = .zoneMissing
        } catch {
            lastPong = "Pong failed: \(error.localizedDescription)"
        }
    }

    private func describe(_ status: CKAccountStatus) -> String {
        switch status {
        case .available: "available"
        case .noAccount: "No iCloud account on this iPhone."
        case .restricted: "iCloud is restricted on this iPhone."
        case .couldNotDetermine: "Couldn't check the iCloud account."
        case .temporarilyUnavailable: "iCloud is temporarily unavailable."
        @unknown default: "Unknown iCloud status."
        }
    }
}
