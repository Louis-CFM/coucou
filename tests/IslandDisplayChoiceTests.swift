import Foundation

@main
enum IslandDisplayChoiceTests {
    static func main() {
        // Storage round-trip, unknown values fall back to the notch default.
        for choice: IslandDisplayChoice in [.notch, .menuBar, .followMouse, .display(uuid: "ABC-123")] {
            precondition(IslandDisplayChoice(storageValue: choice.storageValue) == choice)
        }
        precondition(IslandDisplayChoice(storageValue: "") == .notch)
        precondition(IslandDisplayChoice(storageValue: "garbage") == .notch)
        precondition(IslandDisplayChoice(storageValue: "display:") == .notch)

        // External screen holds the menu bar, MacBook (with notch) is second, mouse on the third.
        let screens = [
            IslandDisplayCandidate(uuid: "EXT-1", hasNotch: false, containsMouse: false),
            IslandDisplayCandidate(uuid: "MBP",   hasNotch: true,  containsMouse: false),
            IslandDisplayCandidate(uuid: "EXT-2", hasNotch: false, containsMouse: true),
        ]
        precondition(IslandDisplayResolver.index(for: .notch, in: screens) == 1)
        precondition(IslandDisplayResolver.index(for: .menuBar, in: screens) == 0)
        precondition(IslandDisplayResolver.index(for: .followMouse, in: screens) == 2)
        precondition(IslandDisplayResolver.index(for: .display(uuid: "EXT-2"), in: screens) == 2)

        // A disconnected chosen screen falls back to the notch screen.
        precondition(IslandDisplayResolver.index(for: .display(uuid: "GONE"), in: screens) == 1)

        // No notch anywhere (lid closed): nil means "use the main screen".
        let desk = [
            IslandDisplayCandidate(uuid: "EXT-1", hasNotch: false, containsMouse: false),
            IslandDisplayCandidate(uuid: "EXT-2", hasNotch: false, containsMouse: false),
        ]
        precondition(IslandDisplayResolver.index(for: .notch, in: desk) == nil)
        precondition(IslandDisplayResolver.index(for: .display(uuid: "GONE"), in: desk) == nil)
        // Mouse between screens (rounding at an edge): keep the default.
        precondition(IslandDisplayResolver.index(for: .followMouse, in: desk) == nil)

        precondition(IslandDisplayResolver.index(for: .menuBar, in: []) == nil)

        print("IslandDisplayChoice tests passed")
    }
}
