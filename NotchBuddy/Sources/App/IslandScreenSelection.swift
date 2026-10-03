import AppKit

struct IslandScreenChoice: Identifiable {
    let id: String
    let name: String
}
enum IslandScreenSelection {
    /// UUIDs identify displays across restarts; display numbers can change.
    @MainActor static func id(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    @MainActor static func availableScreens() -> [IslandScreenChoice] {
        NSScreen.screens.enumerated().compactMap { index, screen in
            guard let id = id(for: screen) else { return nil }
            let size = "\(Int(screen.frame.width)) × \(Int(screen.frame.height))"
            return IslandScreenChoice(id: id, name: "\(index + 1). \(screen.localizedName) · \(size)")
        }
    }

    @MainActor static func preferredScreen(id preferredID: String) -> NSScreen? {
        let screens = NSScreen.screens
        let ids = screens.map { id(for: $0) ?? "" }
        let notchIndex = screens.firstIndex { $0.safeAreaInsets.top > 0 }
        guard let index = selectedIndex(preferredID: preferredID, availableIDs: ids,
                                        notchIndex: notchIndex) else { return nil }
        return screens[index]
    }

    /// Automatic fallback is stable: notch first, then the primary display,
    /// never the display of whichever app currently has keyboard focus.
    static func selectedIndex(preferredID: String, availableIDs: [String],
                              notchIndex: Int?) -> Int? {
        guard !availableIDs.isEmpty else { return nil }
        if !preferredID.isEmpty, let index = availableIDs.firstIndex(of: preferredID) {
            return index
        }
        if let index = notchIndex, availableIDs.indices.contains(index) { return index }
        return 0
    }
}
