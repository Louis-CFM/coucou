#if !APPSTORE
import AppKit

/// Watches the Mac's media keys (volume, brightness, keyboard backlight) with a CGEvent tap.
///
/// Each press goes to `onAction`, which applies it and says whether it did. Only then is
/// the key swallowed (with its repeats and its key-up), so macOS doesn't change the level
/// a second time nor show its own HUD. Anything `onAction` can't apply goes on to macOS
/// untouched, so the keys never stop working because of Coucou.
///
/// Needs Accessibility (System Settings → Privacy & Security → Accessibility).
@MainActor
final class MediaKeyTap {
    static let shared = MediaKeyTap()
    static let logFile = "system-hud.log"

    /// Applies an action on the main thread; returns true when it did (the key is then
    /// swallowed). Called from inside the tap: it must stay quick.
    var onAction: (@MainActor (SystemHUDAction) -> Bool)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// Keys whose key-down Coucou took: their repeats and key-up are taken too.
    private var swallowed: Set<MediaKey> = []

    var isRunning: Bool { tap != nil }

    private init() {}

    /// Starts the tap. Returns false when macOS refuses it (Accessibility not granted).
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        // NX_SYSDEFINED (14): media keys arrive as system-defined events, not key events,
        // so the tap sees nothing you type.
        let mask = CGEventMask(1) << CGEventMask(Self.systemDefinedType)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mediaKeyTapCallback,
            userInfo: nil
        ) else {
            appendAppLog(Self.logFile, "tap refused (Accessibility trusted: \(AXIsProcessTrusted()))")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        appendAppLog(Self.logFile, "tap started")
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        self.source = nil
        swallowed.removeAll()
        appendAppLog(Self.logFile, "tap stopped")
    }

    /// NX_SYSDEFINED: the CGEvent type media keys arrive as.
    nonisolated static let systemDefinedType: UInt32 = 14

    /// One media key press with its modifiers: plain values, safe to hand to the main actor.
    struct Input: Sendable {
        let press: MediaKeyPress
        let option: Bool
        let shift: Bool
    }

    /// Reads a media key press out of a system-defined event; nil for anything else.
    /// Nonisolated: the CGEvent stays in the callback and only the decoded values
    /// cross to the main actor, which is what Swift 6's data-race checks ask for.
    nonisolated static func read(_ event: CGEvent) -> Input? {
        guard let nsEvent = NSEvent(cgEvent: event),
              nsEvent.type == .systemDefined,
              Int(nsEvent.subtype.rawValue) == SystemHUDLogic.auxControlButtonsSubtype,
              let press = SystemHUDLogic.decode(data1: nsEvent.data1) else { return nil }
        let flags = nsEvent.modifierFlags
        return Input(press: press, option: flags.contains(.option), shift: flags.contains(.shift))
    }

    /// macOS turns a tap off when its callback is slow, or on some user input: turn it back on.
    fileprivate func reenable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        swallowed.removeAll()
        appendAppLog(Self.logFile, "tap re-enabled")
    }

    /// Returns true when the event must be swallowed.
    fileprivate func handle(_ input: Input) -> Bool {
        let press = input.press
        let action = SystemHUDLogic.action(for: press, option: input.option, shift: input.shift)
        guard let action else {
            // Key-up, or a repeat that does nothing (mute): follow what the key-down got.
            if !press.isDown { return swallowed.remove(press.key) != nil }
            return swallowed.contains(press.key)
        }
        let handled = onAction?(action) ?? false
        if handled { swallowed.insert(press.key) } else { swallowed.remove(press.key) }
        #if DEBUG
        appendAppLog(Self.logFile,
                     "key \(press.key) repeat=\(press.isRepeat) option=\(input.option) "
                     + "shift=\(input.shift) → \(action) handled=\(handled)")
        #endif
        return handled
    }
}

/// The tap's C callback. It runs on the main run loop, where the source was added.
/// Returns nil to swallow a key Coucou applied; every other event goes on untouched.
private func mediaKeyTapCallback(proxy: CGEventTapProxy, type: CGEventType,
                                 event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        MainActor.assumeIsolated { MediaKeyTap.shared.reenable() }
    default:
        if type.rawValue == MediaKeyTap.systemDefinedType, let input = MediaKeyTap.read(event) {
            let swallow = MainActor.assumeIsolated { MediaKeyTap.shared.handle(input) }
            if swallow { return nil }
        }
    }
    return Unmanaged.passUnretained(event)
}
#endif
