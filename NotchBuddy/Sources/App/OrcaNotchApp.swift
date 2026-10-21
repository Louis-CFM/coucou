import SwiftUI
import AppKit

@main
struct OrcaNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            // ⌘, and Orca Notch → Settings… open the Settings window.
            CommandGroup(replacing: .appSettings) {
                Button(NSLocalizedString("Settings…", comment: "")) {
                    delegate.openSettings()
                }
                .keyboardShortcut(",")
            }
        }
    }
}
