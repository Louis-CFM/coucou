import CloudKit
import Observation
import UIKit
import UserNotifications

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
    var lastPong: String?
    var pushError: String?
    var notificationsAllowed: Bool?

    @ObservationIgnored private let container = CKContainer(identifier: PhoneLink.containerID)
    @ObservationIgnored private var database: CKDatabase { container.privateCloudDatabase }
    @ObservationIgnored private var changeToken: CKServerChangeToken?
    @ObservationIgnored private var firstFetchDone = false
    @ObservationIgnored private var subscribed = false
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
        _ = await fetchChanges()
    }

    /// Called on a CloudKit push. Returns true when new records arrived.
    func handlePush() async -> Bool {
        await fetchChanges()
    }

    private func subscribe() async {
        let sub = CKDatabaseSubscription(subscriptionID: Self.subscriptionID)
        // Silent: the Mac now writes on every session change, a banner each
        // time would be noise. Real notifications come with step 7.
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
                changeToken = changes.changeToken
                more = changes.moreComing
            }
            firstFetchDone = true
            status = .ready
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
        if record.recordType == "Session" {
            let item = SessionItem(record: record)
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
