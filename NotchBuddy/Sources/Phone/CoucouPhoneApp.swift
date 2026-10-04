import SwiftUI
import UIKit
import UserNotifications
import CloudKit

// Coucou on iPhone — step 1 spike: a "link test" screen that shows the Pings
// written by the Mac in the shared private CloudKit zone and answers with Pongs.

@main
struct CoucouPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            LinkTestView(link: PhoneLink.shared)
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

    // Show the "Ping from your Mac" banner even when the app is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
