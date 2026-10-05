#if PHONE_LINK
import AppKit
import CloudKit

// MARK: - iPhone link
//
// Starts and stops the iPhone sync (Settings → General → iPhone, off by
// default): push registration and SessionPublisher. Nothing runs and nothing
// is sent to iCloud while it is off.
//
// Step 1 spike, kept for testing: when the phoneLinkPing default is on, proves
// that the Mac and the iPhone app share a private CloudKit database:
// writes a `Ping` every 60 s, waits for the iPhone's `Pong`, and logs the
// round trip to ~/Library/Logs/NotchBuddy/nb.log. Pongs arrive both through a
// silent push (CKDatabaseSubscription) and a 5 s poll, so the log shows which
// path is faster. Compiled only with PHONE_LINK; normal builds never see it.

@MainActor
final class CloudProbe {
    static let shared = CloudProbe()

    static let containerID = "iCloud.fr.louisraille.Coucou"
    static let zoneID = CKRecordZone.ID(zoneName: "Coucou", ownerName: CKCurrentUserDefaultName)
    private static let subscriptionID = "coucou-zone-mac"

    private let container = CKContainer(identifier: CloudProbe.containerID)
    private var database: CKDatabase { container.privateCloudDatabase }

    private let launchDate = Date()
    private var ready = false
    private var pingCount = 0
    private var changeToken: CKServerChangeToken?
    private var seenPongs = Set<String>()
    private var fetching = false
    private var lastPushAt: Date?
    private var started = false
    private var pingTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    private var appLabel: String {
        #if APPSTORE
        "CoucouAppStore"
        #else
        "NotchBuddy"
        #endif
    }

    private var macName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    static let enabledKey = "iPhoneSyncEnabled"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Called at launch: starts only if the user turned the iPhone sync on.
    func startIfEnabled() {
        if Self.isEnabled { start() }
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { start() } else { stop() }
    }

    private func stop() {
        guard started else { return }
        started = false
        pingTask?.cancel(); pingTask = nil
        pollTask?.cancel(); pollTask = nil
        NSApplication.shared.unregisterForRemoteNotifications()
        SessionPublisher.shared.stop()
        ApprovalRelay.shared.stop()
        QuestionRelay.shared.stop()
        ServiceDetailRunner.shared.stop()
        ServicePublisher.shared.stop()
        TurnRecorder.shared.stop()
        #if !APPSTORE
        InstructionRunner.shared.stop()
        #endif
        LiveActivityRelay.shared.stop()
        log("iPhone sync off")
    }

    private func start() {
        guard !started else { return }
        started = true
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        log("starting (\(appLabel), \(build) build, container \(Self.containerID))")
        NSApplication.shared.registerForRemoteNotifications()
        SessionPublisher.shared.start()
        ApprovalRelay.shared.start()
        QuestionRelay.shared.start()
        ServiceDetailRunner.shared.start()
        ServicePublisher.shared.start()
        TurnRecorder.shared.start()
        #if !APPSTORE
        InstructionRunner.shared.startIfEnabled()
        #endif
        LiveActivityRelay.shared.startIfEnabled()
        // The silent database subscription, so the iPhone's requests (services) wake this Mac.
        Task { _ = await prepare() }

        // Step 1 Ping/Pong test: off unless asked for, so the Mac stays idle at rest
        // (defaults write fr.louisraille.NotchBuddy phoneLinkPing -bool YES).
        guard UserDefaults.standard.bool(forKey: "phoneLinkPing") else {
            log("ping test off (phoneLinkPing)")
            return
        }
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pingTick()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await self?.fetchChanges(source: "poll")
            }
        }
    }

    // MARK: Setup

    /// Checks the iCloud account, creates the zone and the subscription.
    /// Returns false (and logs why) when iCloud isn't usable yet; retried on the next tick.
    private func prepare() async -> Bool {
        if ready { return true }
        do {
            let status = try await container.accountStatus()
            guard status == .available else {
                log("iCloud account not available (status \(describe(status))), will retry in 60 s")
                return false
            }
            _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: Self.zoneID)], deleting: [])
            log("zone Coucou ready")

            let sub = CKDatabaseSubscription(subscriptionID: Self.subscriptionID)
            let info = CKSubscription.NotificationInfo()
            info.shouldSendContentAvailable = true // silent push
            sub.notificationInfo = info
            _ = try await database.modifySubscriptions(saving: [sub], deleting: [])
            log("database subscription saved")
            let subs = try await database.allSubscriptions()
            log("subscriptions on this iCloud account: \(subs.map(\.subscriptionID).sorted().joined(separator: ", "))")
            ready = true
            return true
        } catch {
            log("setup failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Ping

    private func pingTick() async {
        guard await prepare() else { return }
        pingCount += 1
        let record = CKRecord(recordType: "Ping",
                              recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: Self.zoneID))
        let sentAt = Date()
        record["macName"] = macName
        record["app"] = appLabel
        record["sentAt"] = sentAt
        record.encryptedValues["message"] = "Ping #\(pingCount) from \(appLabel)"
        do {
            _ = try await database.save(record)
            log("Ping #\(pingCount) saved in \(String(format: "%.1f", Date().timeIntervalSince(sentAt))) s")
        } catch {
            log("Ping #\(pingCount) failed: \(error.localizedDescription)")
        }
    }

    // MARK: Pong

    func handleRemoteNotification(_ userInfo: [String: Any]) {
        guard CKNotification(fromRemoteNotificationDictionary: userInfo) != nil else {
            log("remote notification received, not from CloudKit (keys: \(userInfo.keys.sorted().joined(separator: ", ")))")
            return
        }
        lastPushAt = Date()
        // A request from the iPhone (a service to read, an action) may be waiting.
        Task { await ServiceDetailRunner.shared.checkNow() }
        guard pingTask != nil else { return }   // the Pong fetch is only for the ping test
        log("push received")
        Task { await fetchChanges(source: "push") }
    }

    private func fetchChanges(source: String) async {
        guard ready, !fetching else { return }
        fetching = true
        defer { fetching = false }
        do {
            var more = true
            while more {
                let changes = try await database.recordZoneChanges(inZoneWith: Self.zoneID, since: changeToken)
                for (_, result) in changes.modificationResultsByID {
                    if case .success(let mod) = result { handle(mod.record, source: source) }
                }
                changeToken = changes.changeToken
                more = changes.moreComing
            }
        } catch let error as CKError where error.code == .changeTokenExpired {
            changeToken = nil
        } catch let error as CKError where error.code == .zoneNotFound {
            log("zone Coucou missing, recreating")
            ready = false
        } catch {
            log("fetch (\(source)) failed: \(error.localizedDescription)")
        }
    }

    private func handle(_ record: CKRecord, source: String) {
        guard record.recordType == "Pong" else { return }
        let id = record.recordID.recordName
        guard !seenPongs.contains(id) else { return }
        seenPongs.insert(id)
        // Older pongs from previous runs: remember them, don't log them.
        guard let created = record.creationDate, created >= launchDate else { return }

        let message = record.encryptedValues["message"] as? String ?? "?"
        var line = "Pong from iPhone: \(message)"
        if let pingSentAt = record["pingSentAt"] as? Date {
            line += String(format: ", round trip %.1f s", Date().timeIntervalSince(pingSentAt))
        }
        if let repliedAt = record["repliedAt"] as? Date {
            line += String(format: ", %.1f s after the tap", Date().timeIntervalSince(repliedAt))
        }
        line += " (via \(source)"
        if source == "poll", let push = lastPushAt, Date().timeIntervalSince(push) < 10 {
            line += ", push came \(String(format: "%.1f", Date().timeIntervalSince(push))) s ago"
        }
        line += ")"
        log(line)
    }

    // MARK: Helpers

    private func describe(_ status: CKAccountStatus) -> String {
        switch status {
        case .available: "available"
        case .noAccount: "no account"
        case .restricted: "restricted"
        case .couldNotDetermine: "could not determine"
        case .temporarilyUnavailable: "temporarily unavailable"
        @unknown default: "unknown"
        }
    }

    /// Writes to nb.log and to the Xcode console (the sandboxed build's nb.log
    /// sits in its container, which Terminal can't read).
    func log(_ message: String) {
        appendAppLog("nb.log", "[PhoneLink] \(message)")
        print("[PhoneLink] \(message)")
    }
}

extension AppDelegate {
    @objc func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.prefix(4).map { String(format: "%02x", $0) }.joined()
        CloudProbe.shared.log("registered for remote notifications (token \(token)…)")
    }

    @objc func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        CloudProbe.shared.log("remote notification registration failed: \(error.localizedDescription)")
    }

    @objc func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        CloudProbe.shared.handleRemoteNotification(userInfo)
    }
}
#endif
