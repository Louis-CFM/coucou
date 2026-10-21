import AppKit
import SwiftUI

/// The Settings window: opened from the menu bar, the island's gear or a hotkey.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(section: String? = nil) {
        if let section { UserDefaults.standard.set(section, forKey: "settingsSection") }
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "Orca Notch"
        win.contentView = NSHostingView(rootView: SettingsView())
        win.contentMinSize = NSSize(width: 720, height: 480)
        win.isReleasedWhenClosed = false
        win.setFrameAutosaveName("OrcaNotchSettingsWindow")
        if !win.setFrameUsingName("OrcaNotchSettingsWindow") { win.center() }
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
