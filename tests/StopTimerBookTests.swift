@MainActor
final class Fired {
    var names: [String] = []
}

@main
enum StopTimerBookTests {
    @MainActor
    static func main() async {
        let book = StopTimerBook()
        let fired = Fired()

        book.arm("a", after: 0.05) { fired.names.append("a") }
        book.arm("b", after: 0.05) { fired.names.append("b") }
        precondition(book.cancel("a"), "an armed timer can be cancelled")
        try? await Task.sleep(for: .milliseconds(300))
        precondition(fired.names == ["b"], "\(fired.names)")
        precondition(!book.isArmed("b"))
        precondition(!book.cancel("b"), "a timer that fired is no longer armed")

        // Arming again replaces the earlier timer of that pill.
        book.arm("c", after: 0.05) { fired.names.append("c1") }
        book.arm("c", after: 0.05) { fired.names.append("c2") }
        try? await Task.sleep(for: .milliseconds(300))
        precondition(fired.names == ["b", "c2"], "\(fired.names)")
        print("StopTimerBook tests passed")
    }
}
