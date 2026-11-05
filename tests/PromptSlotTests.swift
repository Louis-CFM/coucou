import Foundation

@main
enum PromptSlotTests {

    static var failures = 0

    static func check(_ label: String, _ ok: Bool) {
        if ok { print("  ✓ \(label)") }
        else  { print("  ✗ \(label)"); failures += 1 }
    }

    typealias Pill = PromptSlot.Pill
    typealias Content = PromptSlot.Content

    static let hermesA = Pill.hermes(agent: "a")
    static let hermesB = Pill.hermes(agent: "b")
    static let cmuxT = Pill.cmux(taskId: "t")
    static let cmuxU = Pill.cmux(taskId: "u")
    static let other = Pill.other

    static func main() {
        // ── contentOnOpen ──────────────────────────────────────────────────────
        print("contentOnOpen")
        check("1. Hermes pill gives its chat",
              PromptSlot.contentOnOpen(focus: hermesA, cmuxAvailable: true) == .hermesChat(agent: "a")
              && PromptSlot.contentOnOpen(focus: hermesA, cmuxAvailable: false) == .hermesChat(agent: "a"))
        check("2. cmux pill, cmux available: the reply of that pill, session not resolved yet",
              PromptSlot.contentOnOpen(focus: cmuxT, cmuxAvailable: true) == .cmuxReply(taskId: "t", surfaceKey: nil))
        check("3. cmux pill, cmux not available: the shared chat",
              PromptSlot.contentOnOpen(focus: cmuxT, cmuxAvailable: false) == .sharedChat)
        check("4. other pill: the shared chat",
              PromptSlot.contentOnOpen(focus: other, cmuxAvailable: true) == .sharedChat
              && PromptSlot.contentOnOpen(focus: other, cmuxAvailable: false) == .sharedChat)

        check("4b. an opener that carries context: a cmux pill gets the shared chat, never its reply",
              PromptSlot.contentOnOpen(focus: cmuxT, cmuxAvailable: true, carriesContext: true) == .sharedChat
              && PromptSlot.belongs(.sharedChat, to: cmuxT))
        check("4c. an opener that carries context: Hermes and other pills are unchanged",
              PromptSlot.contentOnOpen(focus: hermesA, cmuxAvailable: true, carriesContext: true) == .hermesChat(agent: "a")
              && PromptSlot.contentOnOpen(focus: other, cmuxAvailable: true, carriesContext: true) == .sharedChat
              && PromptSlot.contentOnOpen(focus: cmuxT, cmuxAvailable: true, carriesContext: false) == .cmuxReply(taskId: "t", surfaceKey: nil))

        // ── belongs ────────────────────────────────────────────────────────────
        print("belongs")
        let allPills = [hermesA, hermesB, cmuxT, cmuxU, other]
        check("5. a Hermes chat belongs to its own pill only",
              PromptSlot.belongs(.hermesChat(agent: "a"), to: hermesA)
              && !PromptSlot.belongs(.hermesChat(agent: "a"), to: hermesB)
              && !PromptSlot.belongs(.hermesChat(agent: "a"), to: cmuxT)
              && !PromptSlot.belongs(.hermesChat(agent: "a"), to: other))
        check("6. a cmux reply belongs to its own pill only",
              PromptSlot.belongs(.cmuxReply(taskId: "t", surfaceKey: "s1"), to: cmuxT)
              && !PromptSlot.belongs(.cmuxReply(taskId: "t", surfaceKey: "s1"), to: cmuxU)
              && !PromptSlot.belongs(.cmuxReply(taskId: "t", surfaceKey: "s1"), to: hermesA)
              && !PromptSlot.belongs(.cmuxReply(taskId: "t", surfaceKey: "s1"), to: other))
        check("7. the shared chat belongs to anything that is not a Hermes pill",
              PromptSlot.belongs(.sharedChat, to: other)
              && PromptSlot.belongs(.sharedChat, to: cmuxT)
              && !PromptSlot.belongs(.sharedChat, to: hermesA))
        check("8. a new cmux chat belongs to every pill",
              allPills.allSatisfy { PromptSlot.belongs(.cmuxNewChat, to: $0) })

        // ── onFocusChange ──────────────────────────────────────────────────────
        print("onFocusChange")
        check("9. closed, Hermes pill by pointer: its chat is shown",
              PromptSlot.onFocusChange(open: nil, newFocus: hermesA, byPointer: true) == .show(.hermesChat(agent: "a")))
        check("10. closed, Hermes pill by keyboard: nothing",
              PromptSlot.onFocusChange(open: nil, newFocus: hermesA, byPointer: false) == .keep)
        check("11. closed, cmux or other pill: nothing",
              PromptSlot.onFocusChange(open: nil, newFocus: cmuxT, byPointer: true) == .keep
              && PromptSlot.onFocusChange(open: nil, newFocus: cmuxT, byPointer: false) == .keep
              && PromptSlot.onFocusChange(open: nil, newFocus: other, byPointer: true) == .keep
              && PromptSlot.onFocusChange(open: nil, newFocus: other, byPointer: false) == .keep)
        let replyT = Content.cmuxReply(taskId: "t", surfaceKey: "s1")
        check("12. reply of t open, focus on t: keep",
              PromptSlot.onFocusChange(open: replyT, newFocus: cmuxT, byPointer: false) == .keep
              && PromptSlot.onFocusChange(open: replyT, newFocus: cmuxT, byPointer: true) == .keep)
        check("13. reply of t open, focus on cmux u: close",
              PromptSlot.onFocusChange(open: replyT, newFocus: cmuxU, byPointer: false) == .close
              && PromptSlot.onFocusChange(open: replyT, newFocus: cmuxU, byPointer: true) == .close)
        check("14. reply of t open, Hermes pill by pointer: its chat is shown",
              PromptSlot.onFocusChange(open: replyT, newFocus: hermesA, byPointer: true) == .show(.hermesChat(agent: "a")))
        check("15. chat of a open, Hermes b: shown by pointer, closed by keyboard",
              PromptSlot.onFocusChange(open: .hermesChat(agent: "a"), newFocus: hermesB, byPointer: true) == .show(.hermesChat(agent: "b"))
              && PromptSlot.onFocusChange(open: .hermesChat(agent: "a"), newFocus: hermesB, byPointer: false) == .close)
        check("16. chat of a open, cmux or other pill: close",
              PromptSlot.onFocusChange(open: .hermesChat(agent: "a"), newFocus: cmuxT, byPointer: true) == .close
              && PromptSlot.onFocusChange(open: .hermesChat(agent: "a"), newFocus: cmuxT, byPointer: false) == .close
              && PromptSlot.onFocusChange(open: .hermesChat(agent: "a"), newFocus: other, byPointer: true) == .close
              && PromptSlot.onFocusChange(open: .hermesChat(agent: "a"), newFocus: other, byPointer: false) == .close)
        check("17. shared chat open: a Hermes pill by keyboard closes it, another pill keeps it",
              PromptSlot.onFocusChange(open: .sharedChat, newFocus: hermesA, byPointer: false) == .close
              && PromptSlot.onFocusChange(open: .sharedChat, newFocus: other, byPointer: false) == .keep
              && PromptSlot.onFocusChange(open: .sharedChat, newFocus: other, byPointer: true) == .keep)
        check("18. new cmux chat open: any focus keeps it",
              allPills.allSatisfy { PromptSlot.onFocusChange(open: .cmuxNewChat, newFocus: $0, byPointer: false) == .keep })

        // ── mayDeliver ─────────────────────────────────────────────────────────
        print("mayDeliver")
        check("19. same reply, same session: yes",
              PromptSlot.mayDeliver(rendered: replyT, resolved: .cmuxReply(taskId: "t", surfaceKey: "s1")))
        check("20. same task, another session: no",
              !PromptSlot.mayDeliver(rendered: replyT, resolved: .cmuxReply(taskId: "t", surfaceKey: "s2")))
        check("21. rendered session unknown: no, even when the resolved one is nil too",
              !PromptSlot.mayDeliver(rendered: .cmuxReply(taskId: "t", surfaceKey: nil), resolved: .cmuxReply(taskId: "t", surfaceKey: "s1"))
              && !PromptSlot.mayDeliver(rendered: .cmuxReply(taskId: "t", surfaceKey: nil), resolved: .cmuxReply(taskId: "t", surfaceKey: nil)))
        check("22. chat of agent a against chat of agent b: no",
              !PromptSlot.mayDeliver(rendered: .hermesChat(agent: "a"), resolved: .hermesChat(agent: "b"))
              && PromptSlot.mayDeliver(rendered: .hermesChat(agent: "a"), resolved: .hermesChat(agent: "a")))
        check("23. shared chat against shared chat: yes; against anything else: no",
              PromptSlot.mayDeliver(rendered: .sharedChat, resolved: .sharedChat)
              && !PromptSlot.mayDeliver(rendered: .sharedChat, resolved: .hermesChat(agent: "a"))
              && !PromptSlot.mayDeliver(rendered: replyT, resolved: .sharedChat))

        // ── textMayDeliver / retargetNeedsNotice ───────────────────────────────
        print("text owner")
        check("39. text owned by what is rendered: deliver",
              PromptSlot.textMayDeliver(owner: replyT, rendered: replyT)
              && PromptSlot.textMayDeliver(owner: .sharedChat, rendered: .sharedChat))
        check("40. text owned by another session, chat or agent: refuse",
              !PromptSlot.textMayDeliver(owner: replyT, rendered: .cmuxReply(taskId: "t", surfaceKey: "s2"))
              && !PromptSlot.textMayDeliver(owner: .hermesChat(agent: "a"), rendered: .hermesChat(agent: "b"))
              && !PromptSlot.textMayDeliver(owner: .sharedChat, rendered: .hermesChat(agent: "a")))
        check("41. no owner: refuse",
              !PromptSlot.textMayDeliver(owner: nil, rendered: replyT)
              && !PromptSlot.textMayDeliver(owner: nil, rendered: .sharedChat))
        let replyT2 = Content.cmuxReply(taskId: "t", surfaceKey: "s2")
        check("42. rendered content moved under typed text, not by the user: notice",
              PromptSlot.retargetNeedsNotice(owner: replyT, rendered: replyT2, textIsEmpty: false, byUser: false))
        check("43. no notice for a chip click, an empty field, an unchanged content or no owner",
              !PromptSlot.retargetNeedsNotice(owner: replyT, rendered: replyT2, textIsEmpty: false, byUser: true)
              && !PromptSlot.retargetNeedsNotice(owner: replyT, rendered: replyT2, textIsEmpty: true, byUser: false)
              && !PromptSlot.retargetNeedsNotice(owner: replyT, rendered: replyT, textIsEmpty: false, byUser: false)
              && !PromptSlot.retargetNeedsNotice(owner: nil, rendered: replyT2, textIsEmpty: false, byUser: false))
        // Whatever the order of the callbacks: edits are stored under the owner, so the draft of s1 keeps the text
        // typed for s1 and s2 never receives it.
        var ordered = PromptDrafts()
        let owner = replyT
        ordered.set("hello", for: owner)
        ordered.set("hellox", for: owner)           // the keystroke, stored under the owner at edit time
        check("44. store only: an edit filed under its owner leaves another content's draft empty; delivery to the new content is refused (the setter itself lives in the views, covered by hand check H9)",
              ordered.text(for: replyT) == "hellox" && ordered.text(for: replyT2).isEmpty
              && !PromptSlot.textMayDeliver(owner: owner, rendered: replyT2))

        // ── cardSurface ────────────────────────────────────────────────────────
        print("cardSurface")
        check("45. the card session counts only while its answer is shown",
              PromptSlot.cardSurface(finalLineKey: "c", finalLineShown: true) == "c"
              && PromptSlot.cardSurface(finalLineKey: "c", finalLineShown: false) == nil
              && PromptSlot.cardSurface(finalLineKey: nil, finalLineShown: true) == nil)
        check("46. answer no longer shown, chip live: the chip wins",
              PromptSlot.replySurface(cardSurface: PromptSlot.cardSurface(finalLineKey: "c", finalLineShown: false),
                                      choice: "x", main: "m", live: ["c", "x", "m"]) == "x")

        // ── answerMayTakeSlot / draftAfterSend ─────────────────────────────────
        print("answer slot, sent draft")
        check("47. a shared chat answer takes the slot only if the shared chat is what the slot would show, no card is pending, and nothing else is on screen",
              PromptSlot.answerMayTakeSlot(onScreen: nil, chatContent: .sharedChat, cardPending: false)
              && PromptSlot.answerMayTakeSlot(onScreen: .sharedChat, chatContent: .sharedChat, cardPending: false)
              && !PromptSlot.answerMayTakeSlot(onScreen: replyT, chatContent: .sharedChat, cardPending: false)
              && !PromptSlot.answerMayTakeSlot(onScreen: .cmuxNewChat, chatContent: .sharedChat, cardPending: false)
              && !PromptSlot.answerMayTakeSlot(onScreen: .hermesChat(agent: "a"), chatContent: .sharedChat, cardPending: false))
        check("47b. slot closed but the chat it would show is a Hermes chat, or a card is pending: the view does not change",
              !PromptSlot.answerMayTakeSlot(onScreen: nil, chatContent: .hermesChat(agent: "a"), cardPending: false)
              && !PromptSlot.answerMayTakeSlot(onScreen: nil, chatContent: .sharedChat, cardPending: true)
              && !PromptSlot.answerMayTakeSlot(onScreen: .sharedChat, chatContent: .sharedChat, cardPending: true))
        check("48. after a send the sent text goes; only text appended after the press stays",
              PromptSlot.draftAfterSend(draft: "hi", sent: "hi") == ""
              && PromptSlot.draftAfterSend(draft: "hi there", sent: "hi") == " there"
              && PromptSlot.draftAfterSend(draft: "oh hi", sent: "hi") == ""
              && PromptSlot.draftAfterSend(draft: "x", sent: "hi") == ""
              && PromptSlot.draftAfterSend(draft: "", sent: "hi") == "")

        // ── the chat view owns chat contents only (Aegis N1) ───────────────────
        print("chat view / cmux view")
        let chatOwners: [Content?] = [.sharedChat, .hermesChat(agent: "a")]
        check("49. chat view: owner cmux reply, same cmux reply on screen: refuse",
              !PromptSlot.chatTextMayDeliver(owner: replyT, onScreen: replyT, cmuxPromptOpen: true)
              && !PromptSlot.chatTextMayDeliver(owner: replyT, onScreen: replyT, cmuxPromptOpen: false)
              && !PromptSlot.chatTextMayDeliver(owner: .cmuxNewChat, onScreen: .cmuxNewChat, cmuxPromptOpen: true))
        check("50. chat view: a chat owner delivers only to the same chat, with no cmux prompt open",
              PromptSlot.chatTextMayDeliver(owner: .sharedChat, onScreen: .sharedChat, cmuxPromptOpen: false)
              && PromptSlot.chatTextMayDeliver(owner: .hermesChat(agent: "a"), onScreen: .hermesChat(agent: "a"), cmuxPromptOpen: false)
              && !PromptSlot.chatTextMayDeliver(owner: .hermesChat(agent: "a"), onScreen: .hermesChat(agent: "b"), cmuxPromptOpen: false)
              && !PromptSlot.chatTextMayDeliver(owner: .sharedChat, onScreen: .hermesChat(agent: "a"), cmuxPromptOpen: false)
              && !PromptSlot.chatTextMayDeliver(owner: nil, onScreen: .sharedChat, cmuxPromptOpen: false))
        check("51. chat view: a cmux prompt open refuses even a chat owner on a chat content",
              chatOwners.allSatisfy { !PromptSlot.chatTextMayDeliver(owner: $0, onScreen: $0 ?? .sharedChat, cmuxPromptOpen: true) })
        check("52. chat view loads a draft only for a chat content with no cmux prompt open",
              PromptSlot.chatMayLoadDraft(onScreen: .sharedChat, cmuxPromptOpen: false)
              && PromptSlot.chatMayLoadDraft(onScreen: .hermesChat(agent: "a"), cmuxPromptOpen: false)
              && !PromptSlot.chatMayLoadDraft(onScreen: replyT, cmuxPromptOpen: true)
              && !PromptSlot.chatMayLoadDraft(onScreen: replyT, cmuxPromptOpen: false)
              && !PromptSlot.chatMayLoadDraft(onScreen: .cmuxNewChat, cmuxPromptOpen: false)
              && !PromptSlot.chatMayLoadDraft(onScreen: .sharedChat, cmuxPromptOpen: true)
              && !PromptSlot.chatMayLoadDraft(onScreen: nil, cmuxPromptOpen: false))
        check("53. mirror: the cmux view never delivers text owned by a chat, and the chat kinds are not cmux",
              !PromptSlot.textMayDeliver(owner: .sharedChat, rendered: replyT)
              && !PromptSlot.textMayDeliver(owner: .hermesChat(agent: "a"), rendered: .cmuxNewChat)
              && PromptSlot.isChat(.sharedChat) && PromptSlot.isChat(.hermesChat(agent: "a"))
              && !PromptSlot.isChat(replyT) && !PromptSlot.isChat(.cmuxNewChat))

        // ── unknown shared provider (Hera N1) ──────────────────────────────────
        print("shared chat opener with Hermes selected")
        check("54. shared chat wanted, provider is not Hermes: nothing to do",
              PromptSlot.sharedOpen(providerIsHermes: false, lastSharedKnown: false, activeAgent: "a") == .keep
              && PromptSlot.sharedOpen(providerIsHermes: false, lastSharedKnown: true, activeAgent: nil) == .keep)
        check("55. shared chat wanted, provider is Hermes, last shared known: back to the shared provider",
              PromptSlot.sharedOpen(providerIsHermes: true, lastSharedKnown: true, activeAgent: "a") == .backToShared)
        check("56. shared chat wanted, provider is Hermes, last shared unknown: the active agent's chat and the focus moves to its pill",
              PromptSlot.sharedOpen(providerIsHermes: true, lastSharedKnown: false, activeAgent: "a") == .hermesChat(agent: "a")
              && PromptSlot.sharedOpen(providerIsHermes: true, lastSharedKnown: false, activeAgent: nil) == .hermesChat(agent: nil))

        // ── failed send (Hera N3) ──────────────────────────────────────────────
        print("draft after a failed send")
        check("57. failed send: the draft already holds the prompt, or more: it is left alone",
              PromptSlot.draftAfterFailure(draft: "hi", prompt: "hi") == "hi"
              && PromptSlot.draftAfterFailure(draft: "hi there", prompt: "hi") == "hi there"
              && PromptSlot.draftAfterFailure(draft: "oh hi", prompt: "hi") == "oh hi")
        check("58. failed send: the draft is empty, the prompt comes back; other newer text stays exactly as typed, without the prompt in front",
              PromptSlot.draftAfterFailure(draft: "", prompt: "hi") == "hi"
              && PromptSlot.draftAfterFailure(draft: "new", prompt: "hi") == "new"
              && PromptSlot.draftAfterFailure(draft: " new ", prompt: "hi") == " new "
              && PromptSlot.draftAfterFailure(draft: "new", prompt: "") == "new"
              && PromptSlot.draftAfterFailure(draft: "", prompt: "") == "")

        // ── failed prompt and a draft that cannot be seen (Hera I4) ─────────
        check("59. failed send: a draft of spaces or newlines only counts as empty, the prompt comes back; real text stays untouched",
              PromptSlot.draftAfterFailure(draft: " ", prompt: "hi") == "hi"
              && PromptSlot.draftAfterFailure(draft: " \n\t ", prompt: "hi") == "hi"
              && PromptSlot.draftAfterFailure(draft: "  new  ", prompt: "hi") == "  new  ")
        check("60. the prompt is stashed only when other text stays in the field",
              PromptSlot.failureLosesPrompt(draft: "new", prompt: "hi")
              && PromptSlot.failureLosesPrompt(draft: " new ", prompt: "hi")
              && !PromptSlot.failureLosesPrompt(draft: "", prompt: "hi")
              && !PromptSlot.failureLosesPrompt(draft: "  ", prompt: "hi")
              && !PromptSlot.failureLosesPrompt(draft: "hi", prompt: "hi")
              && !PromptSlot.failureLosesPrompt(draft: " hi ", prompt: "hi")
              && !PromptSlot.failureLosesPrompt(draft: "new", prompt: " "))
        check("61. the notice that says to check the prompt needs the prompt in the field",
              PromptSlot.promptIsInField(draft: "hi", prompt: "hi")
              && !PromptSlot.promptIsInField(draft: "other", prompt: "hi")
              && !PromptSlot.promptIsInField(draft: "", prompt: "hi"))
        do {
            let reply = PromptSlot.Content.cmuxReply(taskId: "t", surfaceKey: "k")
            var stash = PromptStash()
            stash.keep("first", for: .cmuxNewChat)
            check("62. a stashed prompt comes back once, for its own content only",
                  stash.take(for: reply) == nil && stash.take(for: .cmuxNewChat) == "first" && stash.take(for: .cmuxNewChat) == nil)
            stash.keep("one", for: .cmuxNewChat); stash.keep("two", for: .cmuxNewChat)
            check("63. a newer prompt of the same content replaces the older, never merged",
                  stash.take(for: .cmuxNewChat) == "two")
            stash.keep("   ", for: .cmuxNewChat)
            check("64. a blank prompt is not stashed", stash.count == 0)
            for i in 0..<(PromptStash.maxEntries + 5) { stash.keep("p\(i)", for: .cmuxReply(taskId: "t\(i)", surfaceKey: nil)) }
            check("65. the stash is capped, oldest dropped first",
                  stash.count == PromptStash.maxEntries
                  && stash.take(for: .cmuxReply(taskId: "t0", surfaceKey: nil)) == nil
                  && stash.take(for: .cmuxReply(taskId: "t\(PromptStash.maxEntries + 4)", surfaceKey: nil)) != nil)
            stash.removeAll()
            stash.keep("a", for: reply); stash.keep("b", for: .cmuxReply(taskId: "t", surfaceKey: nil)); stash.keep("c", for: .cmuxReply(taskId: "u", surfaceKey: "k"))
            stash.forgetReplies(ofTask: "t")
            check("66. the end of a session forgets the stashed prompts of its replies, whatever their surface",
                  stash.take(for: reply) == nil && stash.take(for: .cmuxReply(taskId: "t", surfaceKey: nil)) == nil
                  && stash.take(for: .cmuxReply(taskId: "u", surfaceKey: "k")) == "c")
            stash.keep("x", for: .cmuxNewChat); stash.keep("y", for: reply)
            stash.removeAll()
            check("67. clearing the conversation or the app session empties the stash", stash.count == 0)
            stash.keep(String(repeating: "a", count: PromptStash.maxLength + 50), for: .cmuxNewChat)
            check("68. a long prompt is cut to the cap, not dropped",
                  stash.take(for: .cmuxNewChat)?.count == PromptStash.maxLength)
        }

        // ── the stash comes back when the field is next loaded, and ages out (Aegis L3) ──
        do {
            let t0 = Date(timeIntervalSince1970: 1_000_000)
            check("69. the age rule takes the clock as a parameter: fresh up to one hour, never from the future",
                  PromptStash.maxAge == 3600
                  && PromptStash.isFresh(storedAt: t0, now: t0)
                  && PromptStash.isFresh(storedAt: t0, now: t0.addingTimeInterval(3600))
                  && !PromptStash.isFresh(storedAt: t0, now: t0.addingTimeInterval(3601))
                  && !PromptStash.isFresh(storedAt: t0, now: t0.addingTimeInterval(-1)))
            var stash = PromptStash()
            stash.keep("first", for: .cmuxNewChat, at: t0)
            check("70. a stashed prompt older than an hour is not put back, and is dropped",
                  stash.take(for: .cmuxNewChat, at: t0.addingTimeInterval(3601)) == nil && stash.count == 0)
            stash.keep("first", for: .cmuxNewChat, at: t0)
            check("71. a fresh one comes back once",
                  stash.take(for: .cmuxNewChat, at: t0.addingTimeInterval(3599)) == "first" && stash.take(for: .cmuxNewChat, at: t0) == nil)
            stash.keep("old", for: .cmuxNewChat, at: t0)
            stash.keep("new", for: .cmuxNewChat, at: t0.addingTimeInterval(3000))
            check("72. a newer prompt of the same content restarts the age",
                  stash.take(for: .cmuxNewChat, at: t0.addingTimeInterval(6000)) == "new")
            check("73. the field loads the stash only when the stored draft is blank",
                  PromptSlot.draftForLoad(stored: "", stashed: "first") == PromptSlot.LoadedDraft(text: "first", restoredStash: true)
                  && PromptSlot.draftForLoad(stored: " \n", stashed: "first") == PromptSlot.LoadedDraft(text: "first", restoredStash: true)
                  && PromptSlot.draftForLoad(stored: "typed", stashed: "first") == PromptSlot.LoadedDraft(text: "typed", restoredStash: false)
                  && PromptSlot.draftForLoad(stored: "", stashed: nil) == PromptSlot.LoadedDraft(text: "", restoredStash: false)
                  && PromptSlot.draftForLoad(stored: "typed", stashed: nil) == PromptSlot.LoadedDraft(text: "typed", restoredStash: false))
            // Aegis L3: loading a field that holds other text must leave the stash where it is
            var loadStash = PromptStash()
            loadStash.keep("P1", for: .cmuxNewChat)
            let keptText = PromptSlot.loadDraft(stored: "D other text", stash: &loadStash, for: .cmuxNewChat)
            check("73b. a load over other text does not take the stash",
                  keptText == PromptSlot.LoadedDraft(text: "D other text", restoredStash: false) && loadStash.count == 1)
            let laterLoad = PromptSlot.loadDraft(stored: "", stash: &loadStash, for: .cmuxNewChat)
            check("73c. a later load of the empty field gets it, once",
                  laterLoad == PromptSlot.LoadedDraft(text: "P1", restoredStash: true) && loadStash.count == 0)
            loadStash.keep("P2", for: .cmuxNewChat)
            let noTake = PromptSlot.loadDraft(stored: "", stash: &loadStash, for: .cmuxNewChat, takesStash: false)
            check("73d. a reload caused by a writer never takes it",
                  noTake == PromptSlot.LoadedDraft(text: "", restoredStash: false) && loadStash.count == 1)
            let reply = PromptSlot.Content.cmuxReply(taskId: "t", surfaceKey: "k")
            check("74. the restored notice fits a reply field with no other notice, and nothing else",
                  PromptSlot.restoredNoticeFits(content: reply, noticeInUse: false)
                  && !PromptSlot.restoredNoticeFits(content: reply, noticeInUse: true)
                  && !PromptSlot.restoredNoticeFits(content: .cmuxNewChat, noticeInUse: false)
                  && !PromptSlot.restoredNoticeFits(content: .sharedChat, noticeInUse: false))
        }

        // ── session closed under typed text (Hera N5) ──────────────────────────
        print("session closed notice")
        check("59. a closed session notices only when its own reply is on screen and held text",
              PromptSlot.closedSessionNeedsNotice(rendered: replyT, dropped: replyT, draftWasEmpty: false)
              && !PromptSlot.closedSessionNeedsNotice(rendered: replyT, dropped: replyT, draftWasEmpty: true)
              && !PromptSlot.closedSessionNeedsNotice(rendered: nil, dropped: replyT, draftWasEmpty: false)
              && !PromptSlot.closedSessionNeedsNotice(rendered: replyT2, dropped: replyT, draftWasEmpty: false))

        // ── reopensOnHermesChat ────────────────────────────────────────────────
        print("reopensOnHermesChat")
        check("24. focus on the agent's pill, unseen answer: yes",
              PromptSlot.reopensOnHermesChat(focus: hermesA, activeAgent: "a", unseenAnswer: true, turnRunning: false, alertPending: false))
        check("25. focus on the agent's pill, turn running: yes",
              PromptSlot.reopensOnHermesChat(focus: hermesA, activeAgent: "a", unseenAnswer: false, turnRunning: true, alertPending: false))
        check("26. focus on another pill: no",
              !PromptSlot.reopensOnHermesChat(focus: cmuxT, activeAgent: "a", unseenAnswer: true, turnRunning: true, alertPending: false)
              && !PromptSlot.reopensOnHermesChat(focus: hermesB, activeAgent: "a", unseenAnswer: true, turnRunning: true, alertPending: false)
              && !PromptSlot.reopensOnHermesChat(focus: other, activeAgent: "a", unseenAnswer: true, turnRunning: true, alertPending: false))
        check("27. alert pending: no",
              !PromptSlot.reopensOnHermesChat(focus: hermesA, activeAgent: "a", unseenAnswer: true, turnRunning: true, alertPending: true))
        check("28. no active agent: no; nothing to show: no",
              !PromptSlot.reopensOnHermesChat(focus: hermesA, activeAgent: nil, unseenAnswer: true, turnRunning: true, alertPending: false)
              && !PromptSlot.reopensOnHermesChat(focus: hermesA, activeAgent: "a", unseenAnswer: false, turnRunning: false, alertPending: false))

        // ── replySurface ───────────────────────────────────────────────────────
        print("replySurface")
        check("29. the session of the card is live: it wins over the chip and the main one",
              PromptSlot.replySurface(cardSurface: "c", choice: "x", main: "m", live: ["c", "x", "m"]) == "c")
        check("30. the card session is gone: the chip",
              PromptSlot.replySurface(cardSurface: "c", choice: "x", main: "m", live: ["x", "m"]) == "x"
              && PromptSlot.replySurface(cardSurface: nil, choice: "x", main: "m", live: ["x", "m"]) == "x")
        check("31. card and chip gone: the main session",
              PromptSlot.replySurface(cardSurface: "c", choice: "x", main: "m", live: ["m"]) == "m"
              && PromptSlot.replySurface(cardSurface: nil, choice: nil, main: "m", live: ["m"]) == "m")
        check("32. nothing live: nil",
              PromptSlot.replySurface(cardSurface: "c", choice: "x", main: "m", live: []) == nil
              && PromptSlot.replySurface(cardSurface: nil, choice: nil, main: nil, live: ["z"]) == nil)

        // ── PromptDrafts ───────────────────────────────────────────────────────
        print("PromptDrafts")
        var drafts = PromptDrafts()
        drafts.set("for a", for: .hermesChat(agent: "a"))
        check("33. a draft set for A is not returned for B, nor for the shared chat",
              drafts.text(for: .hermesChat(agent: "a")) == "for a"
              && drafts.text(for: .hermesChat(agent: "b")).isEmpty
              && drafts.text(for: .sharedChat).isEmpty)

        drafts = PromptDrafts()
        drafts.set("one", for: .cmuxReply(taskId: "t", surfaceKey: "s1"))
        drafts.set("two", for: .cmuxReply(taskId: "t", surfaceKey: "s2"))
        check("34. two sessions of one task keep two drafts",
              drafts.text(for: .cmuxReply(taskId: "t", surfaceKey: "s1")) == "one"
              && drafts.text(for: .cmuxReply(taskId: "t", surfaceKey: "s2")) == "two"
              && drafts.text(for: .cmuxReply(taskId: "t", surfaceKey: nil)).isEmpty)

        drafts = PromptDrafts()
        drafts.set("keep", for: .sharedChat)
        drafts.set("drop", for: .hermesChat(agent: "a"))
        drafts.clear(.hermesChat(agent: "a"))
        check("35. clear removes one draft only",
              drafts.text(for: .hermesChat(agent: "a")).isEmpty && drafts.text(for: .sharedChat) == "keep")
        drafts.set("again", for: .hermesChat(agent: "a"))
        drafts.set("", for: .hermesChat(agent: "a"))
        check("35b. setting an empty text removes the draft",
              drafts.text(for: .hermesChat(agent: "a")).isEmpty && drafts.count == 1)

        drafts = PromptDrafts()
        for i in 0...PromptDrafts.maxEntries {
            drafts.set("draft \(i)", for: .hermesChat(agent: "agent\(i)"))
        }
        check("36. more than maxEntries drops the oldest",
              drafts.count == PromptDrafts.maxEntries
              && drafts.text(for: .hermesChat(agent: "agent0")).isEmpty
              && drafts.text(for: .hermesChat(agent: "agent1")) == "draft 1"
              && drafts.text(for: .hermesChat(agent: "agent\(PromptDrafts.maxEntries)")) == "draft \(PromptDrafts.maxEntries)")
        // Writing again to the oldest entry makes it the newest.
        drafts = PromptDrafts()
        for i in 0..<PromptDrafts.maxEntries { drafts.set("d\(i)", for: .hermesChat(agent: "agent\(i)")) }
        drafts.set("fresh", for: .hermesChat(agent: "agent0"))
        drafts.set("new", for: .sharedChat)
        check("36b. an entry written again is not the oldest any more",
              drafts.text(for: .hermesChat(agent: "agent0")) == "fresh"
              && drafts.text(for: .hermesChat(agent: "agent1")).isEmpty)

        drafts = PromptDrafts()
        drafts.set(String(repeating: "x", count: PromptDrafts.maxLength + 500), for: .sharedChat)
        check("37. a text longer than maxLength is cut",
              drafts.text(for: .sharedChat).count == PromptDrafts.maxLength)

        drafts = PromptDrafts()
        drafts.set("live", for: .hermesChat(agent: "a"))
        drafts.set("gone", for: .hermesChat(agent: "b"))
        drafts.set("gone too", for: .cmuxReply(taskId: "t", surfaceKey: "s1"))
        drafts.set("shared", for: .sharedChat)
        drafts.prune { content in
            if case .hermesChat(let agent) = content { return agent == "a" }
            return content == .sharedChat
        }
        check("38. prune drops the contents that are not live",
              drafts.count == 2
              && drafts.text(for: .hermesChat(agent: "a")) == "live"
              && drafts.text(for: .sharedChat) == "shared"
              && drafts.text(for: .hermesChat(agent: "b")).isEmpty
              && drafts.text(for: .cmuxReply(taskId: "t", surfaceKey: "s1")).isEmpty)

        print(failures == 0 ? "\nAll prompt slot tests passed." : "\n\(failures) failure(s).")
        exit(failures == 0 ? 0 : 1)
    }
}
