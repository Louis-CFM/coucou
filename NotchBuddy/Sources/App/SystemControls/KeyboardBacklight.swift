#if !APPSTORE
import Foundation

/// The MacBook keyboard's backlight, through CoreBrightness's KeyboardBrightnessClient.
///
/// Private framework (what Control Center's Keyboard Brightness slider uses), loaded at
/// run time. Every method is checked with responds(to:) before it is called, so a macOS
/// update that changes it makes `level()` return nil (the key goes on to macOS) instead
/// of crashing Coucou.
@MainActor
final class KeyboardBacklight {
    static let shared = KeyboardBacklight()

    private typealias GetFn = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias SetFn = @convention(c) (AnyObject, Selector, Float, UInt64) -> ObjCBool

    private let client: NSObject?
    private let keyboardID: UInt64
    private let getSel = NSSelectorFromString("brightnessForKeyboard:")
    private let setSel = NSSelectorFromString("setBrightness:forKeyboard:")

    private init() {
        _ = Bundle(path: "/System/Library/PrivateFrameworks/CoreBrightness.framework")?.load()
        guard let type = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else {
            client = nil
            keyboardID = 1
            return
        }
        let client = type.init()
        self.client = client
        // The built-in keyboard's ID (1 on every MacBook so far, asked for in case).
        var id: UInt64 = 1
        let idsSel = NSSelectorFromString("copyKeyboardBacklightIDs")
        if client.responds(to: idsSel),
           let ids = client.perform(idsSel)?.takeRetainedValue() as? [NSNumber],
           let first = ids.first {
            id = first.uint64Value
        }
        keyboardID = id
    }

    /// 0…1, or nil when the API is missing.
    func level() -> Double? {
        guard let client, client.responds(to: getSel) else { return nil }
        let get = unsafeBitCast(client.method(for: getSel), to: GetFn.self)
        let value = Double(get(client, getSel, keyboardID))
        return value.isFinite ? min(max(value, 0), 1) : nil
    }

    /// Returns false when the API is missing or refused the change.
    func setLevel(_ level: Double) -> Bool {
        guard let client, client.responds(to: setSel) else { return false }
        let set = unsafeBitCast(client.method(for: setSel), to: SetFn.self)
        return set(client, setSel, Float(min(max(level, 0), 1)), keyboardID).boolValue
    }
}
#endif
