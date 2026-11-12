#if !APPSTORE
import AppKit
import Carbon

/// The custom shortcut of Flow dictation (Settings → Hold to dictate → Custom shortcut): one to six
/// keys held together, kept by their virtual key codes in the order they were pressed (⌘ then ⇧
/// reads "⌘ ⇧").
enum FlowShortcut {
    static let defaultsKey = "flowCustomShortcut"

    static var order: [UInt16] {
        get { (UserDefaults.standard.array(forKey: defaultsKey) as? [Int] ?? []).map { UInt16(clamping: $0) } }
        set { UserDefaults.standard.set(newValue.map { Int($0) }, forKey: defaultsKey) }
    }

    static var saved: Set<UInt16> { Set(order) }

    /// One key on a key cap: "⌥", "⌥ de droite", "D", "F13", "␣"…
    @MainActor static func capName(_ code: UInt16) -> String {
        if FlowShortcutRules.rightModifiers.contains(code), let symbol = modifierSymbol(code) {
            return String(format: String(localized: "flow.key-right %@"), symbol)
        }
        return shortName(code)
    }

    /// The whole shortcut on one line, compact: "⌃ ⌥ D".
    @MainActor static func compact(_ keys: [UInt16]) -> String {
        keys.map(shortName).joined(separator: " ")
    }

    @MainActor static func shortName(_ code: UInt16) -> String {
        if let symbol = modifierSymbol(code) { return symbol }
        if let name = special[code] { return name }
        return typed(code) ?? "#\(code)"
    }

    private static func modifierSymbol(_ code: UInt16) -> String? {
        switch code {
        case 59, 62: return "⌃"
        case 58, 61: return "⌥"
        case 56, 60: return "⇧"
        case 55, 54: return "⌘"
        case 63:     return "fn"
        default:     return nil
        }
    }

    private static let special: [UInt16: String] = [
        36: "↩", 76: "⌤", 48: "⇥", 49: "␣", 51: "⌫", 117: "⌦", 53: "esc", 57: "⇪",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟", 114: "Help",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20",
    ]

    /// What the key types in the current keyboard layout, without modifiers: "D" on QWERTY and
    /// AZERTY alike for the same letter, "Q" where AZERTY has it.
    @MainActor private static func typed(_ code: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { bytes -> String? in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var dead: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            let text = String(utf16CodeUnits: chars, count: length).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text.uppercased()
        }
    }
}

/// Watches the custom shortcut anywhere on the Mac. An event tap, not an NSEvent monitor: it is the
/// only way to keep the shortcut's own key (the D of ⌃⌥D) from reaching the app in front. The
/// modifier keys always go through, as with the right ⌥.
///
/// Installed only while Flow dictation uses a custom shortcut, so the other keys cost nothing.
@MainActor
final class FlowShortcutTap {
    var onDown: (@MainActor () -> Void)?
    var onUp: (@MainActor () -> Void)?
    /// While the shortcut is being recorded in Settings, the tap watches nothing.
    var paused = false {
        didSet { if paused { chord.reset(); swallowed.removeAll() } }
    }

    private var chord: FlowChord
    /// Keys whose press was kept from the app: their release is too.
    private var swallowed: Set<UInt16> = []
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    init(keys: Set<UInt16>) {
        chord = FlowChord(keys: keys)
    }

    /// Fails without the Accessibility permission.
    @discardableResult
    func start() -> Bool {
        guard tap == nil, !chord.keys.isEmpty else { return tap != nil }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: CGEventMask(mask), callback: flowShortcutTapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            appendAppLog("nb.log", "[Flow] the custom shortcut can't be watched (no Accessibility)")
            return false
        }
        let loopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), loopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        source = loopSource
        appendAppLog("nb.log", "[Flow] custom shortcut watched (\(chord.keys.count) key(s))")
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        chord.reset()
        swallowed.removeAll()
    }

    /// From the tap, on the main thread. True keeps the event from the app in front.
    fileprivate func handle(_ type: CGEventType, code: UInt16, flags: UInt64, isRepeat: Bool) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turns a slow tap off: turn it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .flagsChanged:
            guard !paused else { return false }
            // Every modifier from the flags, so a missed event can't leave one stuck.
            var edges: [FlowChord.Edge] = []
            for key in FlowShortcutRules.modifiers {
                guard let bit = FlowShortcutRules.modifierBit(key), flags & bit == 0 else { continue }
                edges.append(chord.release(key))
            }
            for key in FlowShortcutRules.modifiers {
                guard let bit = FlowShortcutRules.modifierBit(key), flags & bit != 0 else { continue }
                edges.append(chord.press(key))
            }
            edges.forEach(fire)
            return false
        case .keyDown:
            guard !paused else { return false }
            // The keyboard's own state (.hidSystemState): the session's state leaves out the keys
            // this tap keeps from the apps, and would call the shortcut's D released while held.
            fire(chord.forget { held in
                held != code && !FlowShortcutRules.modifiers.contains(held)
                    && !CGEventSource.keyState(.hidSystemState, key: CGKeyCode(held))
            })
            if chord.swallows(code) {
                swallowed.insert(code)
                if !isRepeat { fire(chord.press(code)) }
                return true
            }
            if !isRepeat { fire(chord.press(code)) }
            return false
        case .keyUp:
            let mine = swallowed.remove(code) != nil
            if !paused { fire(chord.release(code)) }
            return mine
        default:
            return false
        }
    }

    private func fire(_ edge: FlowChord.Edge) {
        switch edge {
        case .down:
            appendAppLog("nb.log", "[Flow] custom shortcut held")
            onDown?()
        case .up:   onUp?()
        case .none: break
        }
    }
}

private func flowShortcutTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                     refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags.rawValue
    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    // The pointer crosses to the main actor as a plain address (Sendable); the tap lives as long as
    // it is installed, FlowDictation removes it before letting it go.
    let address = UInt(bitPattern: refcon)
    let swallow = MainActor.assumeIsolated { () -> Bool in
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return false }
        return Unmanaged<FlowShortcutTap>.fromOpaque(pointer).takeUnretainedValue()
            .handle(type, code: code, flags: flags, isRepeat: isRepeat)
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

// MARK: - Recording it in Settings

/// Settings: hold the keys together (six at most), let go, then ↩ saves the shortcut; Esc cancels.
/// Pressing keys again after letting go starts a new try. Nothing reaches the app or Flow meanwhile.
@MainActor
final class FlowShortcutRecording: ObservableObject {
    @Published private(set) var isRecording = false
    /// The keys of this try, in the order they were pressed.
    @Published private(set) var keys: [UInt16] = []
    /// All released: the try waits for ↩ (or shows its problem).
    @Published private(set) var captured = false
    @Published private(set) var problem: FlowShortcutRules.Problem?

    /// true: saved; false: cancelled (Esc, Coucou left the front).
    var onFinish: ((Bool) -> Void)?

    private var held: Set<UInt16> = []
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?

    var canSave: Bool { captured && problem == nil && !keys.isEmpty }

    /// Starts listening, or starts a new try when it already listens.
    func start() {
        keys = []
        held = []
        captured = false
        problem = nil
        guard !isRecording else { return }
        isRecording = true
        FlowDictation.shared.recordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            let isKey = event.type == .keyDown || event.type == .keyUp
            let info = (event.type, event.keyCode, UInt64(event.modifierFlags.rawValue), isKey && event.isARepeat)
            MainActor.assumeIsolated { self?.take(type: info.0, code: info.1, flags: info.2, isRepeat: info.3) }
            return nil
        }
        // Coucou in the background no longer gets the keys: the recording stops.
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
    }

    /// Esc, or Coucou left the front: nothing saved.
    func cancel() {
        guard isRecording else { return }
        stop()
        onFinish?(false)
    }

    /// ↩: the shortcut is saved and Flow uses it.
    func save() {
        guard isRecording, canSave else { return }
        let order = keys
        stop()
        FlowDictation.shared.setShortcut(order)
        onFinish?(true)
    }

    /// Stops listening, without a word to the view (it closed the section itself).
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        monitor = nil
        resignObserver = nil
        held = []
        keys = []
        captured = false
        problem = nil
        if isRecording {
            isRecording = false
            FlowDictation.shared.recordingShortcut = false
        }
    }

    private func take(type: NSEvent.EventType, code: UInt16, flags: UInt64, isRepeat: Bool) {
        switch type {
        case .keyDown:
            if code == 36 || code == 76 {                       // ↩ and the keypad's Enter save
                if held.isEmpty { save() }
                return
            }
            if code == 53 {                                     // Esc cancels
                if held.isEmpty { cancel() }
                return
            }
            guard !isRepeat else { return }
            press(code)
        case .keyUp:
            held.remove(code)
        case .flagsChanged:
            guard let bit = FlowShortcutRules.modifierBit(code) else { return }
            if flags & bit != 0 { press(code) } else { held.remove(code) }
        default:
            return
        }
        // Everything released: the try is done, waiting for ↩, or says what is wrong with it.
        if held.isEmpty, !keys.isEmpty, !captured {
            captured = true
            problem = problem ?? FlowShortcutRules.problem(Set(keys))
        }
    }

    private func press(_ code: UInt16) {
        if captured {                                           // a new try
            keys = []
            captured = false
            problem = nil
        }
        held.insert(code)
        guard !keys.contains(code) else { return }
        guard keys.count < FlowChord.maxKeys else { problem = .tooMany; return }
        keys.append(code)
    }
}
#endif
