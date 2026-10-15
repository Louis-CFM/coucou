import Foundation

// MARK: - Shortcut Action

/// Every keyboard shortcut Coucou knows about.
/// The first 10 cases are *global* (registered with Carbon and effective from any app).
/// Island-local shortcuts are documented in `ShortcutLogic.islandShortcuts` but are
/// not managed here — they are handled by a local NSEvent monitor in IslandWindowController.
enum ShortcutAction: String, CaseIterable, Sendable {
    // MARK: Global (Carbon RegisterEventHotKey)
    case toggleIsland      = "toggleIsland"      // ⌘⇧N — open / close island (toggle)
    case openChat          = "openChat"           // ⌃⌥Space — open island on chat, focus field
    case goToAlert         = "goToAlert"          // ⌃⌥A — jump to pending alert
    case jumpToTerminal    = "jumpToTerminal"     // ⌃⌥T — focus agent terminal
    case attachFrontWindow = "attachFrontWindow"  // ⌃⌥W — attach front window (non-AppStore)
    case nextPill          = "nextPill"           // ⌃⌥] — next pill, open if closed
    case prevPill          = "prevPill"           // ⌃⌥[ — previous pill, open if closed
    case muteToggle        = "muteToggle"         // ⌃⌥M — mute / unmute sounds
    case desktopToggle     = "desktopToggle"      // ⌃⌥D — send Mochi to desktop / bring back
    case wardrobeToggle    = "wardrobeToggle"     // ⌃⌥G — open / close wardrobe
    case talkToCoucou      = "talkToCoucou"       // (unset) — start listening without wake phrase (non-AppStore)

    // MARK: UserDefaults keys

    /// Key code storage key. `toggleIsland` reuses the legacy "hotkeyCode" key.
    var udKeyCode: String {
        self == .toggleIsland ? "hotkeyCode" : "shortcut.\(rawValue).keyCode"
    }
    /// Modifier flags storage key. `toggleIsland` reuses the legacy "hotkeyFlags" key.
    var udFlags: String {
        self == .toggleIsland ? "hotkeyFlags" : "shortcut.\(rawValue).flags"
    }
    /// Enabled flag storage key. `toggleIsland` reuses the legacy "hotkeyEnabled" key.
    var udEnabled: String {
        self == .toggleIsland ? "hotkeyEnabled" : "shortcut.\(rawValue).enabled"
    }

    // MARK: Metadata

    var displayName: String {
        switch self {
        case .toggleIsland:      return String(localized: "shortcut.open-close-island")
        case .openChat:          return String(localized: "shortcut.open-chat")
        case .goToAlert:         return String(localized: "shortcut.go-to-alert")
        case .jumpToTerminal:    return String(localized: "shortcut.jump-to-terminal")
        case .attachFrontWindow: return String(localized: "shortcut.attach-front-window")
        case .nextPill:          return String(localized: "shortcut.next-pill")
        case .prevPill:          return String(localized: "shortcut.prev-pill")
        case .muteToggle:        return String(localized: "shortcut.mute-toggle")
        case .desktopToggle:     return String(localized: "shortcut.desktop-toggle")
        case .wardrobeToggle:    return String(localized: "shortcut.wardrobe")
        case .talkToCoucou:      return String(localized: "shortcut.talk-to-coucou")
        }
    }

    /// Whether this action should be omitted from App Store builds.
    var isAppStoreOnly: Bool { false }
    var isNonAppStore: Bool  { self == .attachFrontWindow || self == .talkToCoucou }

    /// Whether the shortcut is enabled by default.
    /// `toggleIsland` and `talkToCoucou` are off by default; all others are on.
    var enabledByDefault: Bool { self != .toggleIsland && self != .talkToCoucou }
}

// MARK: - Shortcut Spec

/// A key + modifier combination stored as plain values (no AppKit dependency).
struct ShortcutSpec: Equatable, Hashable, Sendable {
    /// Virtual key code (matching kVK_* constants and NSEvent.keyCode).
    var keyCode: UInt16
    /// NSEvent.ModifierFlags raw value — only the modifier bits (.command / .shift / .option / .control).
    /// Stored and compared as a plain UInt so this file stays AppKit-free.
    var nsFlags: UInt

    // MARK: NSEvent modifier raw values (stable since macOS 10.x; see AppKit/NSEvent.h)
    static let cmdBit:   UInt = 1 << 20  // NSEvent.ModifierFlags.command  = 1048576
    static let shiftBit: UInt = 1 << 17  // NSEvent.ModifierFlags.shift    = 131072
    static let optBit:   UInt = 1 << 19  // NSEvent.ModifierFlags.option   = 524288
    static let ctrlBit:  UInt = 1 << 18  // NSEvent.ModifierFlags.control  = 262144
    static let modMask:  UInt = cmdBit | shiftBit | optBit | ctrlBit

    /// True when nsFlags contains at least one of ⌘ ⇧ ⌥ ⌃.
    var hasModifier: Bool { nsFlags & ShortcutSpec.modMask != 0 }

    // MARK: Convenience values for the default table

    static let cmdShift: UInt = cmdBit | shiftBit    // 1179648
    static let ctrlOpt:  UInt = ctrlBit | optBit     // 786432
}

// MARK: - Pure logic

/// Stateless helpers for shortcut management — no AppKit, fully unit-testable standalone.
enum ShortcutLogic {

    // MARK: - Default table

    static let defaults: [ShortcutAction: ShortcutSpec] = [
        .toggleIsland:      ShortcutSpec(keyCode: 45, nsFlags: ShortcutSpec.cmdShift), // ⌘⇧N
        .openChat:          ShortcutSpec(keyCode: 49, nsFlags: ShortcutSpec.ctrlOpt),  // ⌃⌥Space
        .goToAlert:         ShortcutSpec(keyCode: 0,  nsFlags: ShortcutSpec.ctrlOpt),  // ⌃⌥A
        .jumpToTerminal:    ShortcutSpec(keyCode: 17, nsFlags: ShortcutSpec.ctrlOpt),  // ⌃⌥T
        .attachFrontWindow: ShortcutSpec(keyCode: 13, nsFlags: ShortcutSpec.ctrlOpt),  // ⌃⌥W
        .nextPill:          ShortcutSpec(keyCode: 30, nsFlags: ShortcutSpec.ctrlOpt),  // ⌃⌥]
        .prevPill:          ShortcutSpec(keyCode: 33, nsFlags: ShortcutSpec.ctrlOpt),  // ⌃⌥[
        .muteToggle:        ShortcutSpec(keyCode: 46, nsFlags: ShortcutSpec.ctrlOpt),  // ⌃⌥M
        .desktopToggle:     ShortcutSpec(keyCode: 2,  nsFlags: ShortcutSpec.ctrlOpt),  // ⌃⌥D
        .wardrobeToggle:    ShortcutSpec(keyCode: 5,  nsFlags: ShortcutSpec.ctrlOpt),  // ⌃⌥G
        .talkToCoucou:      ShortcutSpec(keyCode: 9,  nsFlags: ShortcutSpec.ctrlOpt),  // ⌃⌥V (disabled by default)
    ]

    // MARK: - Load / save (UserDefaults)

    /// Current spec for `action`, falling back to the default if not stored.
    static func hotKey(for action: ShortcutAction) -> ShortcutSpec {
        let ud  = UserDefaults.standard
        let def = defaults[action]!
        let kc  = ud.object(forKey: action.udKeyCode) as? Int ?? Int(def.keyCode)
        let fl  = ud.object(forKey: action.udFlags)   as? Int ?? Int(def.nsFlags)
        return ShortcutSpec(keyCode: UInt16(kc), nsFlags: UInt(fl))
    }

    static func save(_ spec: ShortcutSpec, for action: ShortcutAction) {
        UserDefaults.standard.set(Int(spec.keyCode), forKey: action.udKeyCode)
        UserDefaults.standard.set(Int(spec.nsFlags),  forKey: action.udFlags)
    }

    static func isEnabled(_ action: ShortcutAction) -> Bool {
        UserDefaults.standard.object(forKey: action.udEnabled) as? Bool
            ?? action.enabledByDefault
    }

    static func setEnabled(_ enabled: Bool, for action: ShortcutAction) {
        UserDefaults.standard.set(enabled, forKey: action.udEnabled)
    }

    static func resetToDefault(_ action: ShortcutAction) {
        let def = defaults[action]!
        save(def, for: action)
        setEnabled(action.enabledByDefault, for: action)
    }

    // MARK: - Carbon modifier conversion

    // Carbon modifier bit flags (CarbonCore/Events.h) — no import needed, just constants.
    private static let cCmdKey:   UInt32 = 1 << 8   // cmdKey    = 256
    private static let cShiftKey: UInt32 = 1 << 9   // shiftKey  = 512
    private static let cOptKey:   UInt32 = 1 << 11  // optionKey = 2048
    private static let cCtrlKey:  UInt32 = 1 << 12  // controlKey = 4096

    /// Convert NSEvent modifier flags (as raw UInt) to Carbon modifier bit mask.
    static func carbonModifiers(fromNS nsFlags: UInt) -> UInt32 {
        let cmd   = ShortcutSpec.cmdBit
        let shift = ShortcutSpec.shiftBit
        let opt   = ShortcutSpec.optBit
        let ctrl  = ShortcutSpec.ctrlBit
        var c: UInt32 = 0
        if nsFlags & cmd   != 0 { c |= cCmdKey   }
        if nsFlags & shift != 0 { c |= cShiftKey }
        if nsFlags & opt   != 0 { c |= cOptKey   }
        if nsFlags & ctrl  != 0 { c |= cCtrlKey  }
        return c
    }

    // MARK: - Conflict detection (within Coucou's own shortcuts)

    /// Returns the set of actions whose (keyCode, nsFlags) pair is shared with another action.
    static func duplicates(in specs: [ShortcutAction: ShortcutSpec]) -> Set<ShortcutAction> {
        var seen: [ShortcutSpec: ShortcutAction] = [:]
        var dups: Set<ShortcutAction> = []
        for (action, spec) in specs {
            if let other = seen[spec] {
                dups.insert(action)
                dups.insert(other)
            } else {
                seen[spec] = action
            }
        }
        return dups
    }

    // MARK: - Display string

    /// Human-readable modifier+key string, e.g. "⌃⌥A" or "⌘⇧N".
    static func displayString(for spec: ShortcutSpec) -> String {
        let f = spec.nsFlags
        var s = ""
        if f & ShortcutSpec.ctrlBit  != 0 { s += "⌃" }
        if f & ShortcutSpec.optBit   != 0 { s += "⌥" }
        if f & ShortcutSpec.shiftBit != 0 { s += "⇧" }
        if f & ShortcutSpec.cmdBit   != 0 { s += "⌘" }
        s += keyCodeToString(spec.keyCode)
        return s
    }

    /// Printable name for the most common virtual key codes.
    static func keyCodeToString(_ code: UInt16) -> String {
        let map: [UInt16: String] = [
            0:"A",  1:"S",  2:"D",  3:"F",  4:"H",  5:"G",  6:"Z",  7:"X",
            8:"C",  9:"V",  11:"B", 12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y",
            17:"T", 31:"O", 32:"U", 33:"[", 34:"I", 35:"P", 37:"L", 38:"J",
            40:"K", 45:"N", 46:"M", 30:"]", 49:"Space",
            36:"↩", 51:"⌫", 53:"⎋",
            123:"←", 124:"→", 125:"↓", 126:"↑",
            18:"1", 19:"2", 20:"3", 21:"4", 23:"5", 22:"6", 26:"7", 28:"8", 25:"9",
        ]
        return map[code] ?? "·"
    }

    // MARK: - Card navigation (pure, no AppKit dependency)

    /// Compute the next card-selection index.
    /// - Returns `nil` when `itemCount == 0`.
    /// - Clamps to `0 ..< itemCount`.
    /// - `nil` selection + `delta > 0` → first item; `delta < 0` → last item.
    static func navigate(selection: Int?, delta: Int, itemCount: Int) -> Int? {
        guard itemCount > 0 else { return nil }
        if let cur = selection {
            return max(0, min(itemCount - 1, cur + delta))
        }
        return delta > 0 ? 0 : itemCount - 1
    }

    // MARK: - Island-local shortcut table (read-only, shown in Settings)

    /// Descriptive table of island-local shortcuts for the Settings view.
    static let islandShortcuts: [(key: String, description: String)] = [
        ("⌘→ / ⌘←",    String(localized: "shortcut.island.next-prev")),
        ("⌘1 – ⌘9",    String(localized: "shortcut.island.by-number")),
        ("⌘↓ / ⌘↑",    String(localized: "shortcut.island.nav-items")),
        ("⌘O",          String(localized: "shortcut.island.open")),
        ("⌘E",          String(localized: "shortcut.island.diff")),
        ("⌘↩",          String(localized: "shortcut.island.send")),
        ("⌘K",          String(localized: "shortcut.island.new-convo")),
        ("⌘,",          String(localized: "shortcut.island.settings")),
        ("⌘P",          String(localized: "shortcut.island.pin")),
        ("⎋",           String(localized: "shortcut.island.close")),
    ]
}
