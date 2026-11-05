import Foundation

@main
enum HermesAnnounceTests {
    static var failures = 0

    static func check<T: Equatable>(_ label: String, _ got: T, _ expected: T) {
        if got == expected { print("  ✓ \(label)") }
        else { print("  ✗ \(label)\n    got:      \(got)\n    expected: \(expected)"); failures += 1 }
    }

    static func main() {
        print("HermesAnnounce.decide (all 16 combinations)")
        typealias H = HermesAnnounce
        for bits in 0..<16 {
            let expanded = bits & 8 != 0, chat = bits & 4 != 0, cmux = bits & 2 != 0, alert = bits & 1 != 0
            let expected: H.Outcome = (expanded && chat && !cmux) ? .none : ((alert || cmux) ? .badgeOnly : .expand)
            check("expanded=\(expanded) viewIsChat=\(chat) cmuxPromptOpen=\(cmux) alertPending=\(alert)",
                  H.decide(expanded: expanded, viewIsChat: chat, cmuxPromptOpen: cmux, alertPending: alert), expected)
        }
        check("collapsed with a stale chat view: expand", H.decide(expanded: false, viewIsChat: true, cmuxPromptOpen: false, alertPending: false), .expand)
        check("cmux reply open: badge only, the reply is kept", H.decide(expanded: true, viewIsChat: true, cmuxPromptOpen: true, alertPending: false), .badgeOnly)

        print("HermesAnnounce.chatIsShown")
        check("chat expanded", H.chatIsShown(expanded: true, viewIsChat: true, cmuxPromptOpen: false), true)
        check("cmux prompt in the prompt slot (or opening) is not the chat", H.chatIsShown(expanded: true, viewIsChat: true, cmuxPromptOpen: true), false)
        check("collapsed", H.chatIsShown(expanded: false, viewIsChat: true, cmuxPromptOpen: false), false)
        check("other view", H.chatIsShown(expanded: true, viewIsChat: false, cmuxPromptOpen: false), false)

        print("HermesAnnounce.typingOverride")
        typealias O = H.Override
        check("turn waiting, no override: dots", H.typingOverride(current: .none, anyTurnWaiting: true), O.thinking)
        check("turn waiting, other override kept", H.typingOverride(current: .other, anyTurnWaiting: true), O.other)
        check("nobody waits: dots dropped", H.typingOverride(current: .thinking, anyTurnWaiting: false), O.none)
        check("nobody waits: error of a failed sibling dropped", H.typingOverride(current: .error, anyTurnWaiting: false), O.none)
        check("nobody waits: other override kept", H.typingOverride(current: .other, anyTurnWaiting: false), O.other)
        check("nobody waits, no override", H.typingOverride(current: .none, anyTurnWaiting: false), O.none)

        if failures > 0 { print("\(failures) failure(s)"); exit(1) }
        print("All Hermes announce tests passed")
    }
}
