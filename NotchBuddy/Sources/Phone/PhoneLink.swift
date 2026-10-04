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
    private static let subscriptionID = "coucou-zone-phone"

    var status: Status = .starting
    var pings: [PingItem] = []
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
        let info = CKSubscription.NotificationInfo()
        info.title = "Coucou"
        info.alertBody = "Ping from your Mac"
        info.soundName = "default"
        info.shouldSendContentAvailable = true
        sub.notificationInfo = info
        do {
            _ = try await database.modifySubscriptions(saving: [sub], deleting: [])
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
