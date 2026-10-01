import SwiftUI
import AppKit

@main
struct NotchBuddyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // Settings are shown in an AppKit window (AppDelegate.openSettings); an accessory app
        // has no app menu, so this scene is never reachable — it only satisfies `App`.
        Settings {
            EmptyView()
        }
    }
}
