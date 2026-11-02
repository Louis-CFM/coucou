#if !APPSTORE
import CoreGraphics
import Darwin

/// The built-in screen's brightness, through DisplayServices.
///
/// Apple silicon has no public API for it: DisplayServices is a private framework, the one
/// macOS's own brightness keys and Control Center use. It is loaded at run time and every
/// symbol is checked, so if a macOS update removes it, `level()` returns nil and the
/// brightness keys simply go on to macOS. External displays (DDC) are not handled.
@MainActor
final class DisplayBrightness {
    static let shared = DisplayBrightness()

    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    /// Tells the rest of the system (Control Center's slider) the level changed.
    private typealias ChangedFn = @convention(c) (CGDirectDisplayID, Double) -> Void

    private let getFn: GetFn?
    private let setFn: SetFn?
    private let changedFn: ChangedFn?

    private init() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_LAZY) else {
            getFn = nil; setFn = nil; changedFn = nil
            return
        }
        getFn = dlsym(handle, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetFn.self) }
        setFn = dlsym(handle, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetFn.self) }
        changedFn = dlsym(handle, "DisplayServicesBrightnessChanged").map { unsafeBitCast($0, to: ChangedFn.self) }
        // The handle stays open for the app's life: the function pointers live in it.
    }

    /// 0…1, or nil when there is no built-in screen (lid closed) or no API.
    func level() -> Double? {
        guard let getFn, let display = Self.builtInDisplay() else { return nil }
        var value = Float(0)
        guard getFn(display, &value) == 0 else { return nil }
        return Double(value)
    }

    /// Returns false when the screen or the API is missing, or the change was refused.
    func setLevel(_ level: Double) -> Bool {
        guard let setFn, let display = Self.builtInDisplay() else { return false }
        let clamped = min(max(level, 0), 1)
        guard setFn(display, Float(clamped)) == 0 else { return false }
        changedFn?(display, clamped)
        return true
    }

    /// The MacBook's own screen, if it is on (not with the lid closed).
    private static func builtInDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }
}
#endif
