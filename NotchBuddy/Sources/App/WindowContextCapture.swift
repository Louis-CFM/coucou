import AppKit
import ApplicationServices

// MARK: - Window context capture (M8)

enum WindowContextCapture {

    /// Returns a PromptContext from the given app (typically the last app active before NotchBuddy).
    /// Uses AXUIElement for window title (requires Accessibility permission).
    /// Uses AppleScript for browser URL (Safari, Chrome, Arc, Firefox, Edge).
    static func captureActive(from app: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) -> PromptContext? {
        guard let app, let appName = app.localizedName else { return nil }

        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)

        // --- Window title ---
        var title = ""
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
           let windowRef {
            // swiftlint:disable force_cast
            let axWindow = windowRef as! AXUIElement
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
               let t = titleRef as? String {
                title = t
            }
        }

        // --- Browser URL ---
        let url = browserURL(for: app)

        return .window(appName: appName, title: title, url: url)
    }

    // MARK: - Private

    private static let browserScripts: [String: String] = [
        "com.apple.Safari":
            "tell application \"Safari\" to return URL of current tab of front window",
        "com.google.Chrome":
            "tell application \"Google Chrome\" to return URL of active tab of front window",
        "company.thebrowser.Browser":
            "tell application \"Arc\" to return URL of active tab of front window",
        "org.mozilla.firefox":
            "tell application \"Firefox\" to return URL of active tab of front window",
        "com.microsoft.edgemac":
            "tell application \"Microsoft Edge\" to return URL of active tab of front window",
    ]

    private static func browserURL(for app: NSRunningApplication) -> String? {
        guard let bundleId = app.bundleIdentifier,
              let script = browserScripts[bundleId] else { return nil }
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        return error == nil ? result?.stringValue : nil
    }
}
