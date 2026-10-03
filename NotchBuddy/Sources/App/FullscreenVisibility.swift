import AppKit

enum FullscreenVisibility {
    @MainActor static func shouldHide(on screen: NSScreen?) -> Bool {
        guard let screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return false }
        return shouldHide(onDisplay: number.uint32Value)
    }

    @MainActor static func shouldHide(onDisplay displayID: CGDirectDisplayID) -> Bool {
        decision(onDisplay: displayID) ?? false
    }

    @MainActor static func decision(onDisplay displayID: CGDirectDisplayID) -> Bool? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let bounds = windows.compactMap { window -> CGRect? in
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue != 0,
                  let rectangle = window[kCGWindowBounds as String] as? [String: Any]
            else { return nil }
            return CGRect(dictionaryRepresentation: rectangle as CFDictionary)
        }
        return decision(screen: CGDisplayBounds(displayID), windows: bounds)
    }

    /// Window Server bounds can lag orderFront during a Space transition.
    static func isPanelSettled(expected: CGRect, actual: CGRect?) -> Bool {
        guard let actual else { return false }
        return abs(actual.minX - expected.minX) <= 2 && abs(actual.minY - expected.minY) <= 2
            && abs(actual.width - expected.width) <= 2 && abs(actual.height - expected.height) <= 2
    }

    /// Both rectangles use global Quartz coordinates. A normally maximized
    /// window occupies the visible frame, leaving room for the menu bar or Dock.
    /// Screen-filling borderless windows also qualify; this does not identify Spaces.
    static func shouldHide(screen: CGRect, windows: [CGRect]) -> Bool {
        decision(screen: screen, windows: windows) ?? false
    }

    /// Nil means a screen-wide window is still sliding between Spaces.
    static func decision(screen: CGRect, windows: [CGRect]) -> Bool? {
        guard !screen.isEmpty else { return false }
        // CGWindowList orders windows front to back. Use the frontmost ordinary
        // content window at the display's center. Browsers can expose a separate
        // normal-level toolbar above their fullscreen content (e.g. Zen).
        let center = CGPoint(x: screen.midX, y: screen.midY)
        guard let window = windows.first(where: { $0.contains(center) }) else {
            // The small gap between two sliding Spaces can cross the display center.
            if windows.contains(where: {
                $0.intersects(screen) && abs($0.width - screen.width) <= 2
                    && abs($0.minX - screen.minX) > 2
            }) { return nil }
            return false
        }
        if abs(window.width - screen.width) <= 2 && abs(window.minX - screen.minX) > 2 {
            return nil
        }
        return abs(window.minX - screen.minX) <= 2 && abs(window.minY - screen.minY) <= 2
                && abs(window.width - screen.width) <= 2 && abs(window.height - screen.height) <= 2
    }
}
