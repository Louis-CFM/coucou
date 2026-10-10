import Foundation

@main
enum ConversationContextTests {
    static let pills = PillFixture.available

    static func main() {
        testNoContextReturnsNil()
        testSameTarget_aussiFR()
        testSameTarget_pareilPour()
        testSameTarget_also()
        testReverse_pillAdd()
        testReverse_musicPause()
        testUnknownNotStored()
        print("ConversationContextTests: all cases passed")
    }

    static func testNoContextReturnsNil() {
        let ctx = ConversationContext()
        // "et X aussi" with no prior action defaults to pillAdd (new: bare pill / relative patterns → add)
        precondition(ctx.resolveRelative("et Vercel aussi", pills: pills) == .pillAdd(id: "integration_vercel"),
            "et X aussi without context → pillAdd X")
        // Truly unknown non-relative phrase → nil
        precondition(ctx.resolveRelative("xyz blabla blah", pills: pills) == nil,
            "unknown phrase without context → nil")
    }

    static func testSameTarget_aussiFR() {
        var ctx = ConversationContext()
        ctx.update(.pillAdd(id: "integration_github"))
        let r = ctx.resolveRelative("et vercel aussi", pills: pills)
        precondition(r == .pillAdd(id: "integration_vercel"),
            "et X aussi → pillAdd with X")
    }

    static func testSameTarget_pareilPour() {
        var ctx = ConversationContext()
        ctx.update(.pillRemove(id: "integration_github"))
        let r = ctx.resolveRelative("pareil pour stripe", pills: pills)
        precondition(r == .pillRemove(id: "integration_stripe"),
            "pareil pour X → pillRemove with X")
    }

    static func testSameTarget_also() {
        var ctx = ConversationContext()
        ctx.update(.pillAdd(id: "integration_vercel"))
        let r = ctx.resolveRelative("also stripe", pills: pills)
        precondition(r == .pillAdd(id: "integration_stripe"),
            "also X → pillAdd with X")
    }

    static func testReverse_pillAdd() {
        var ctx = ConversationContext()
        ctx.update(.pillAdd(id: "integration_github"))
        let r = ctx.resolveRelative("annule ca", pills: pills)
        precondition(r == .pillRemove(id: "integration_github"),
            "annule ca after pillAdd → pillRemove")
    }

    static func testReverse_musicPause() {
        var ctx = ConversationContext()
        ctx.update(.musicPause)
        let r = ctx.resolveRelative("undo", pills: pills)
        precondition(r == .musicPlay(target: nil),
            "undo after musicPause → musicPlay")
    }

    static func testUnknownNotStored() {
        var ctx = ConversationContext()
        ctx.update(.unknown)
        precondition(ctx.lastIntent == nil,
            ".unknown should not be stored in context")
    }
}
