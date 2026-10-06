import AppKit
import Carbon.HIToolbox

// MARK: - C-level event handler
//
// Carbon's InstallEventHandler requires a top-level C-compatible function.
// We store state in nonisolated(unsafe) globals — safe because all mutations
// happen on the main thread (Carbon dispatches hot-key events on the main thread).

private nonisolated(unsafe) var gHotKeyHandler: EventHandlerRef? = nil
private nonisolated(unsafe) var gHotKeyTable: [UInt32: ShortcutAction] = [:]
private nonisolated(unsafe) var gOnAction: ((ShortcutAction) -> Void)? = nil

private func coucouHotKeyEventHandler(
    _: EventHandlerCallRef?,
    _ event: EventRef?,
    _: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hkid = EventHotKeyID()
    let err = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hkid
    )
    guard err == noErr, let action = gHotKeyTable[hkid.id] else {
        return OSStatus(eventNotHandledErr)
    }
    // Carbon events are dispatched on the main thread.
    MainActor.assumeIsolated { gOnAction?(action) }
    return noErr
}

// MARK: - HotKeyCenter

/// Manages all global keyboard shortcuts via Carbon `RegisterEventHotKey`.
///
/// - No Accessibility permission required.
/// - Works in the App Store sandbox.
/// - The hot-key event is consumed and never forwarded to the front application.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private init() {}

    // "COUC" in big-endian — unique signature for Coucou's hot-key IDs
    private let kSignature = OSType(0x434F5543)

    // Live registered refs (action → EventHotKeyRef)
    private var refs: [ShortcutAction: EventHotKeyRef] = [:]

    /// Actions whose `RegisterEventHotKey` call failed (system conflict).
    private(set) var conflicts: Set<ShortcutAction> = []

    // MARK: - Lifecycle

    /// Start the hot-key engine and fire `onAction` whenever the user presses a registered shortcut.
    /// Safe to call more than once — the handler is installed only once.
    func start(onAction: @escaping @MainActor (ShortcutAction) -> Void) {
        gOnAction = onAction

        if gHotKeyHandler == nil {
            var spec = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind:  UInt32(kEventHotKeyPressed)
            )
            InstallEventHandler(
                GetApplicationEventTarget(),
                coucouHotKeyEventHandler,
                1, &spec,
                nil, &gHotKeyHandler
            )
        }

        registerAll()
    }

    /// Unregister every hot key. Called on app quit.
    func unregisterAll() {
        for (action, ref) in refs {
            UnregisterEventHotKey(ref)
            let idx = UInt32(ShortcutAction.allCases.firstIndex(of: action)!)
            gHotKeyTable.removeValue(forKey: idx)
        }
        refs.removeAll()
    }

    /// Re-register all shortcuts from the current UserDefaults state.
    func registerAll() {
        unregisterAll()
        conflicts.removeAll()

        for action in ShortcutAction.allCases {
            #if APPSTORE
            if action.isNonAppStore { continue }
            #endif
            if !ShortcutLogic.isEnabled(action) { continue }
            registerOne(action)
        }
    }

    /// Re-register a single action (called after a setting change).
    func reregister(_ action: ShortcutAction) {
        // Remove old registration if present
        if let ref = refs[action] {
            UnregisterEventHotKey(ref)
            let idx = UInt32(ShortcutAction.allCases.firstIndex(of: action)!)
            gHotKeyTable.removeValue(forKey: idx)
            refs.removeValue(forKey: action)
        }
        conflicts.remove(action)

        #if APPSTORE
        if action.isNonAppStore { return }
        #endif
        if !ShortcutLogic.isEnabled(action) { return }
        registerOne(action)
    }

    // MARK: - Private

    private func registerOne(_ action: ShortcutAction) {
        let spec   = ShortcutLogic.hotKey(for: action)
        let carbon = ShortcutLogic.carbonModifiers(fromNS: spec.nsFlags)
        let idx    = UInt32(ShortcutAction.allCases.firstIndex(of: action)!)
        let hkid   = EventHotKeyID(signature: kSignature, id: idx)
        var ref: EventHotKeyRef?

        let status = RegisterEventHotKey(
            UInt32(spec.keyCode),
            carbon,
            hkid,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            refs[action] = ref
            gHotKeyTable[idx] = action
        } else {
            conflicts.insert(action)
        }
    }
}
