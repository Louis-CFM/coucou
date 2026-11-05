import Foundation

@main
enum DemoGuardTests {

    static var failures = 0

    static func check(_ label: String, _ ok: Bool) {
        if ok { print("  ✓ \(label)") }
        else  { print("  ✗ \(label)"); failures += 1 }
    }

    typealias Pending = DemoGuard.Pending

    static func main() {
        print("demo guard")
        let none = Pending()
        check("1. nothing real waits: the demo may show its card and move the view",
              !none.any && DemoGuard.mayShowOwnCard(none) && DemoGuard.mayChangeView(none))

        let approval = Pending(approval: true)
        let question = Pending(question: true)
        let queued = Pending(cmuxQueued: true)
        check("2. a real approval blocks the demo card and the view change",
              !DemoGuard.mayShowOwnCard(approval) && !DemoGuard.mayChangeView(approval))
        check("3. a real question blocks the demo card and the view change",
              !DemoGuard.mayShowOwnCard(question) && !DemoGuard.mayChangeView(question))
        check("4. a queued cmux card blocks the demo card and the view change",
              !DemoGuard.mayShowOwnCard(queued) && !DemoGuard.mayChangeView(queued))
        check("5. every combination with one real thing waiting blocks",
              !DemoGuard.mayShowOwnCard(Pending(approval: true, question: true, cmuxQueued: true))
              && !DemoGuard.mayChangeView(Pending(approval: true, question: false, cmuxQueued: true)))

        // The race of the half second: the check is made again with the state at the write.
        let before = Pending()
        let after = Pending(question: true)
        check("6. a question that arrives between the first check and the write is seen by the second check",
              DemoGuard.mayShowOwnCard(before) && !DemoGuard.mayShowOwnCard(after))

        check("7. the chat step is skipped while a Hermes agent is selected",
              !DemoGuard.showsChatStep(providerIsHermes: true) && DemoGuard.showsChatStep(providerIsHermes: false))

        // A message for a Hermes agent is refused in the caller while the demo runs, before the field is emptied.
        check("8. the demo refuses a message for a Hermes agent",
              !DemoGuard.mayChatSend(demoActive: true, targetIsHermesAgent: true))
        check("9. every other combination may send",
              DemoGuard.mayChatSend(demoActive: true, targetIsHermesAgent: false)
              && DemoGuard.mayChatSend(demoActive: false, targetIsHermesAgent: true)
              && DemoGuard.mayChatSend(demoActive: false, targetIsHermesAgent: false))

        print(failures == 0 ? "\nAll demo guard tests passed." : "\n\(failures) failure(s).")
        exit(failures == 0 ? 0 : 1)
    }
}
