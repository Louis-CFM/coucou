import Foundation

/// Which screen hosts the island. Persisted in UserDefaults as `storageValue`.
enum IslandDisplayChoice: Equatable, Hashable {
    /// Default: the built-in screen with a notch, else the main screen.
    case notch
    /// The screen that carries the menu bar (first in `NSScreen.screens`).
    case menuBar
    /// The island moves to the screen under the cursor while it is not open.
    case followMouse
    /// A specific screen, identified by its display UUID (stable across reboots).
    case display(uuid: String)

    private static let displayPrefix = "display:"

    init(storageValue: String) {
        switch storageValue {
        case "menuBar":     self = .menuBar
        case "followMouse": self = .followMouse
        default:
            if storageValue.hasPrefix(Self.displayPrefix) {
                let uuid = String(storageValue.dropFirst(Self.displayPrefix.count))
                self = uuid.isEmpty ? .notch : .display(uuid: uuid)
            } else {
                self = .notch
            }
        }
    }

    var storageValue: String {
        switch self {
        case .notch:             return "notch"
        case .menuBar:           return "menuBar"
        case .followMouse:       return "followMouse"
        case .display(let uuid): return Self.displayPrefix + uuid
        }
    }
}

/// What the resolver needs to know about a connected screen, in `NSScreen.screens` order.
struct IslandDisplayCandidate {
    let uuid: String?
    let hasNotch: Bool
    let containsMouse: Bool
}

enum IslandDisplayResolver {
    /// Index of the screen that should host the island, or nil to use the default
    /// (notch screen, else main screen). A disconnected chosen screen falls back too.
    static func index(for choice: IslandDisplayChoice,
                      in candidates: [IslandDisplayCandidate]) -> Int? {
        guard !candidates.isEmpty else { return nil }
        let notchIndex = candidates.firstIndex { $0.hasNotch }
        switch choice {
        case .notch:
            return notchIndex
        case .menuBar:
            return 0
        case .followMouse:
            return candidates.firstIndex { $0.containsMouse } ?? notchIndex
        case .display(let uuid):
            return candidates.firstIndex { $0.uuid == uuid } ?? notchIndex
        }
    }
}
