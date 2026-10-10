import Foundation

@main
enum LiveEditsTests {
    static func follow(enabled: Bool = true, stopped: Bool = false, cardPending: Bool = false,
                       expanded: Bool = false, onOverview: Bool = true, typing: Bool = false,
                       followingOther: Bool = false) -> Bool {
        LiveEdits.mayFollow(enabled: enabled, stopped: stopped, cardPending: cardPending, expanded: expanded,
                            onOverview: onOverview, typing: typing, followingOther: followingOther)
    }

    static func main() {
        precondition(follow(), "on, folded island → opens")
        precondition(!follow(enabled: false), "setting off → never")
        precondition(!follow(stopped: true), "closed until the next prompt → no")
        precondition(!follow(cardPending: true), "a waiting card is never covered")
        precondition(follow(expanded: true), "open on the overview → replaces the diff")
        precondition(!follow(expanded: true, onOverview: false), "chat or another view open → no")
        precondition(!follow(expanded: true, typing: true), "typing → no")
        precondition(!follow(expanded: true, followingOther: true), "another session's live diff stays")
        precondition(follow(followingOther: true), "folded: the new edit may take over")
        print("LiveEdits: all passed")
    }
}
