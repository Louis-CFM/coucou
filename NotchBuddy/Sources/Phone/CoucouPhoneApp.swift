import SwiftUI
import UIKit
import UserNotifications
import CloudKit

// Coucou on iPhone: the agent sessions your Mac publishes to iCloud
// (SessionPublisher on the Mac, PhoneLink here).

@main
struct CoucouPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            HomeView(link: PhoneLink.shared)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await PhoneLink.shared.refresh() } }
        }
    }
}

final class PhoneAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        ApprovalActions.register()
        LiveActivityLink.shared.start()
        application.registerForRemoteNotifications()
        Task { await PhoneLink.shared.start() }
        return true
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard CKNotification(fromRemoteNotificationDictionary: userInfo) != nil else { return .noData }
        let gotNew = await PhoneLink.shared.handlePush()
        return gotNew ? .newData : .noData
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in PhoneLink.shared.pushError = message }
    }

    // Approval notification actions.
    //
    // Completion-handler versions, with the handler always called on the main
    // thread: with the async versions iOS finished the tap off the main thread
    // and SwiftUI's app delegate crashed ("Call must be made on main thread").
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        nonisolated(unsafe) let done = completionHandler
        let request = response.notification.request
        guard let fingerprint = PhoneLink.approvalFingerprint(in: request) else {
            DispatchQueue.main.async { done() }
            return
        }
        let note = CKNotification(fromRemoteNotificationDictionary: request.content.userInfo) as? CKQueryNotification
        let pillId = request.content.userInfo["pillId"] as? String
            ?? note?.recordFields?["pillId"] as? String ?? ""
        let denied = response.actionIdentifier == ApprovalActions.deny
        Task { @MainActor in
            await Self.handleApproval(denied: denied, fingerprint: fingerprint, pillId: pillId)
            done()
        }
    }

    @MainActor
    private static func handleApproval(denied: Bool, fingerprint: String, pillId: String) async {
        let link = PhoneLink.shared
        link.noteICloudAlert(fingerprint)
        if denied {
            // Awaited so the decision is saved before iOS suspends the app again.
            let summary = link.sessions.first { $0.approvalFingerprint == fingerprint }?.approvalCommand
            _ = await link.decide(.deny, fingerprint: fingerprint, pillId: pillId,
                                  summary: summary ?? "Denied from the notification")
        } else {
            // Review, or a tap on the notification: open the command, Allow needs Face ID there.
            link.reviewFingerprint = fingerprint
            Task { await link.refresh() }
        }
    }

    // Show banners even when the app is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        nonisolated(unsafe) let done = completionHandler
        // One banner per approval: skip the iCloud alert if the local one is already there.
        let request = notification.request
        guard let fingerprint = PhoneLink.approvalFingerprint(in: request),
              request.identifier != PhoneLink.approvalNotificationID(fingerprint) else {
            DispatchQueue.main.async { done([.banner, .sound]) }
            return
        }
        let localID = PhoneLink.approvalNotificationID(fingerprint)
        Task { @MainActor in
            PhoneLink.shared.noteICloudAlert(fingerprint)
            let shown = await PhoneLink.shownApprovals().contains { $0.id == localID }
            done(shown ? [] : [.banner, .sound])
        }
    }
}
