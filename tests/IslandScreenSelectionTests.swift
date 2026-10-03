import AppKit

@main enum IslandScreenSelectionTests {
    @MainActor static func main() {
        let ids = ["central", "left", "right"]
        precondition(IslandScreenSelection.selectedIndex(preferredID: "left", availableIDs: ids, notchIndex: 2) == 1)
        precondition(IslandScreenSelection.selectedIndex(preferredID: "right", availableIDs: ids, notchIndex: nil) == 2)
        precondition(IslandScreenSelection.selectedIndex(preferredID: "", availableIDs: ids, notchIndex: 2) == 2)
        precondition(IslandScreenSelection.selectedIndex(preferredID: "", availableIDs: ids, notchIndex: nil) == 0)
        precondition(IslandScreenSelection.selectedIndex(preferredID: "missing", availableIDs: ids, notchIndex: 2) == 2)
        precondition(IslandScreenSelection.selectedIndex(preferredID: "missing", availableIDs: ids, notchIndex: nil) == 0)
        precondition(IslandScreenSelection.selectedIndex(preferredID: "left", availableIDs: ["right", "central", "left"], notchIndex: nil) == 2)
        precondition(IslandScreenSelection.selectedIndex(preferredID: "left", availableIDs: ["central"], notchIndex: nil) == 0)
        precondition(IslandScreenSelection.selectedIndex(preferredID: "left", availableIDs: [], notchIndex: nil) == nil)
        precondition(IslandScreenSelection.selectedIndex(preferredID: "", availableIDs: ids, notchIndex: 10) == 0)
        // Validate UUID round trips against the actual connected screens.
        let screens = NSScreen.screens
        let automatic = screens.first { $0.safeAreaInsets.top > 0 } ?? screens.first
        precondition(IslandScreenSelection.preferredScreen(id: "") === automatic)
        precondition(IslandScreenSelection.preferredScreen(id: "missing") === automatic)
        for screen in screens {
            guard let id = IslandScreenSelection.id(for: screen) else { preconditionFailure("Missing display UUID") }
            precondition(IslandScreenSelection.preferredScreen(id: id) === screen)
        }
        print("Screen selection: 10 fallback/reordering cases and \(screens.count) live UUID round trips passed")
    }
}
