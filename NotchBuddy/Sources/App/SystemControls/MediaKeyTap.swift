#if !APPSTORE
import AppKit

/// Watches the Mac's media keys (volume, brightness, keyboard backlight) with a CGEvent tap.
///
/// Spike stage: the tap only looks. Every event goes on to macOS untouched, and each
/// press is written to ~/Library/Logs/NotchBuddy/system-hud.log with the action the HUD
/// would take. A later stage swallows a press only after Coucou has applied it itself,
/// so the keys never stop working if Coucou can't.
///
/// Needs Accessibility (System Settings → Privacy & Security → Accessibility).
@MainActor
final class MediaKeyTap {
    static let shared = MediaKeyTap()
    static let logFile = "system-hud.log"

    /// Called on the main thread for each press the HUD would act on.
    var onAction: ((SystemHUDAction) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

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
        appendAppLog(Self.logFile, "tap re-enabled")
    }

    fileprivate func handle(_ input: Input) {
        let press = input.press
        let action = SystemHUDLogic.action(for: press, option: input.option, shift: input.shift)
        appendAppLog(Self.logFile,
                     "key \(press.key) down=\(press.isDown) repeat=\(press.isRepeat) "
                     + "option=\(input.option) shift=\(input.shift) → \(action.map { "\($0)" } ?? "macOS")")
        if let action { onAction?(action) }
    }
}

/// The tap's C callback. It runs on the main run loop, where the source was added.
/// Spike stage: always hands the event back, so macOS still handles every key.
private func mediaKeyTapCallback(proxy: CGEventTapProxy, type: CGEventType,
                                 event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        MainActor.assumeIsolated { MediaKeyTap.shared.reenable() }
    default:
        if type.rawValue == MediaKeyTap.systemDefinedType, let input = MediaKeyTap.read(event) {
            MainActor.assumeIsolated { MediaKeyTap.shared.handle(input) }
        }
    }
    return Unmanaged.passUnretained(event)
}
#endif
