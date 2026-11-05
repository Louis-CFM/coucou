import Foundation

// The center of the Hermes approvals, run with a fake card slot (no app, no window): which request is on screen, what a click
// does, what releases the slot, the input lock, the island on the way out. The fake records what the center asks of the
// screen; it never answers anything. The queue rules are in HermesApprovalTests; the transports are in the sign in and
// chat tests.
//
// Timing: nothing here depends on a wall clock except waiting for an answer to travel through a Task (polled for up to 5 s;
// it takes a few milliseconds) and the negative checks ("no answer happened") which wait 0.15 s and can only pass more
// easily on a slow machine, never fail because of it. The input lock runs on a clock the test moves by hand.

typealias HA = HermesApproval
typealias Choice = HermesApproval.Choice

@MainActor
final class FakeSlot: HermesCardSlot {
    enum Held: Equatable { case hermes(key: String, pill: String), hook }

    /// Agent identity name -> pill id. A test changes it to remove, rename or collide agents.
    var pills: [String: String] = ["alfred": "agent_hermes_alfred", "mark": "agent_hermes_mark"]
    var held: Held?
    var view = "overview"
    var expanded = true
    var badges = Set<String>()
    var calls: [String] = []
    var events: [String] = []
    var decisions: [(pill: String, allow: Bool)] = []
    var notes: [String] = []
    var collapses = 0
    var readingHeights: [CGFloat?] = []
    weak var center: HermesApprovalCenter?

    var isFree: Bool { held == nil }
    var noCardShown: Bool { held == nil }
    var shownInputKey: String? { if case .hermes(let k, _) = held { return k }; return nil }
    var shownPillId: String? { if case .hermes(_, let p) = held { return p }; return nil }
    var chatOnScreen: Bool { view == "prompt" }
    var viewMarker: String { view }

    func pillId(forAgent name: String) -> String? { pills[name] }
    func present(_ request: HermesApprovalRequest, pillId: String, playSound: Bool) {
        held = .hermes(key: request.requestID, pill: pillId)
        calls.append("present \(request.requestID) \(pillId) sound=\(playSound)")
        view = "approval"
    }
    func clear(pillId: String, agent: String) {
        calls.append("clear \(pillId)")
        if case .hermes(_, let p) = held, p == pillId { held = nil }
    }
    func presentNextAfterHermesCard() -> Bool { center?.presentNextIfFree() ?? false }
    func setReadingHeight(_ height: CGFloat?) { readingHeights.append(height) }
    func setWaitingBadge(pillId: String) { badges.insert(pillId) }
    func clearWaitingBadges(keeping keep: Set<String>) { badges = badges.intersection(keep) }
    func setPillAfterCard(pillId: String, agent: String) { calls.append("pill-after \(pillId)") }
    func recordDecision(pillId: String, allow: Bool) { decisions.append((pillId, allow)) }
    func returnToChat() -> Bool {
        guard expanded else { return false }
        view = "prompt"
        return true
    }
    func showOverview() { view = "overview" }
    func showNote(_ text: String) { notes.append(text); view = "note" }
    func collapse() { collapses += 1 }
    func log(_ event: String) { events.append(event) }

    /// A hook approval (or a cmux question) takes the slot, the way `HookServer` does: the center is told first.
    func hookCardArrives() {
        center?.requeueIfShowing()
        held = .hook
    }
    func hookCardLeaves() {
        held = nil
        _ = center?.presentNextIfFree()
    }
}

/// The answers of the transports: every call counts, and the outcome comes when the test opens the gate.
@MainActor
final class Transport {
    var answered: [(id: String, choice: Choice)] = []
    var outcome: HA.AnswerOutcome = .applied
    var gateOpen = true

    func answer(for id: String) -> HermesApprovalAnswer {
        return { choice in
            await MainActor.run { self.answered.append((id, choice)) }
            while await !self.gateOpen { try? await Task.sleep(nanoseconds: 5_000_000) }
            return await self.outcome
        }
    }
}

@main
enum HermesApprovalCenterTests {
    static var failures = 0

    static func check<T: Equatable>(_ label: String, _ got: T, _ expected: T) {
        if got == expected { print("  ✓ \(label)") }
        else { print("  ✗ \(label)\n    got:      \(got)\n    expected: \(expected)"); failures += 1 }
    }
    static func ok(_ label: String, _ value: Bool) {
        if value { print("  ✓ \(label)") } else { print("  ✗ \(label)"); failures += 1 }
    }

    static func request(_ id: String, agent: String = "alfred", command: String = "rm -rf build/", choices: Set<Choice> = [.once, .session, .always, .deny]) -> HermesApprovalRequest {
        HermesApprovalRequest(agentName: agent, origin: .signIn(frameID: "srq-" + id, runtimeSession: "run-1"), requestID: id,
                              command: command, description: "recursive delete", choices: choices, patternKeys: ["recursive delete"])
    }

    /// Lets the Tasks the center started run, up to 5 s for a condition that must become true.
    @MainActor
    static func waitFor(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<1000 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }
    /// For "nothing happened" checks.
    static func settle() async { try? await Task.sleep(nanoseconds: 150_000_000) }

    /// A center with a fake slot, a clock the test moves and a withdrawn-card timer the test fires.
    @MainActor
    final class Env {
        let slot = FakeSlot()
        let center: HermesApprovalCenter
        let transport = Transport()
        var now: Double = 1000
        var timers: [@MainActor () -> Void] = []
        init() {
            center = HermesApprovalCenter(slot: slot)
            slot.center = center
            center.clock = { [unowned self] in self.now }
            center.afterWithdrawn = { [unowned self] body in self.timers.append(body) }
        }
        func offer(_ r: HermesApprovalRequest, turn: Int = 1) -> Bool { center.offer(r, turn: turn, answer: transport.answer(for: r.requestID)) }
        func unlock() { now += 1 }
        func fireTimers() { let t = timers; timers = []; for body in t { body() } }
    }

    @MainActor
    static func run() async {
        await slotAndClicks()
        await slotRelease()
        await hookCards()
        await inputLock()
        await islandReturn()
        await queueShare()
        await clockAndPills()
        await readingFlow()
    }

    static func main() async {
        await run()
        if failures > 0 { print("\(failures) FAILED"); exit(1) }
        print("Hermes approval center: all cases passed")
    }

    // MARK: Clicks and answers

    @MainActor
    static func slotAndClicks() async {
        print("center: one request, one click")
        var e = Env()
        ok("offer_takes_the_request", e.offer(request("a")))
        check("  it is on screen", e.slot.held, .hermes(key: "a", pill: "agent_hermes_alfred"))
        check("  nothing answered by itself", e.transport.answered.count, 0)
        e.unlock()
        e.center.click(requestID: "a", button: "once")
        check("click_sends_exactly_one_answer", await waitFor { e.transport.answered.count == 1 }, true)
        check("  with the request id and the choice", e.transport.answered.first.map { "\($0.id):\($0.choice.rawValue)" }, "a:once")
        e.center.click(requestID: "a", button: "once")
        e.center.click(requestID: "a", button: "deny")
        await settle()
        check("a second click on the same card sends nothing", e.transport.answered.count, 1)
        check("  the slot is free", e.slot.held, nil)

        print("center: no path answers without a click")
        e = Env()
        _ = e.offer(request("a")); _ = e.offer(request("b")); _ = e.offer(request("c", agent: "mark"))
        e.slot.hookCardArrives()
        e.slot.hookCardLeaves()
        e.center.retain(["zzz"], known: ["a"], turn: 1)
        _ = e.offer(request("d", agent: "mark"), turn: 2)
        e.center.withdraw("b", .timeout)
        e.center.agentRemoved("mark")
        e.fireTimers()
        e.unlock()
        e.center.select(.always, requestID: e.center.queue.shownID ?? "")
        e.center.setReading(true, requestID: e.center.queue.shownID ?? "")
        e.center.reachedEnd(requestID: e.center.queue.shownID ?? "")
        e.center.turnEnded(1, .turnEnded)
        e.fireTimers()
        await settle()
        check("every transition but a click (offer, hook card, retain, withdraw, agent removal, timers, select, turn end) answers nothing",
              e.transport.answered.count, 0)
        e = Env()
        _ = e.offer(request("a"))
        e.unlock()
        e.center.click(requestID: "a", button: "teleport")
        e.center.click(requestID: "a", button: "ask")
        e.center.click(requestID: "zzz", button: "once")
        await settle()
        check("an unknown button, ask and an unknown id send nothing", e.transport.answered.count, 0)
        e = Env()
        _ = e.offer(request("a", choices: [.once, .deny]))
        e.unlock()
        e.center.click(requestID: "a", button: "always")
        e.center.click(requestID: "a", button: "session")
        await settle()
        check("a choice that is not offered is never sent", e.transport.answered.count, 0)

        print("center: the log names the scope, never the command or an id")
        for (button, scope) in [("once", "once"), ("session", "session"), ("always", "always"), ("deny", "deny")] {
            e = Env()
            _ = e.offer(request("req-unique-77", command: "echo SECRET_COMMAND_MARKER"))
            e.unlock()
            e.center.click(requestID: "req-unique-77", button: button)
            _ = await waitFor { e.slot.events.contains { $0.hasPrefix("answered") } }
            check("answer log names the scope (\(scope))", e.slot.events.contains("answer sent scope=\(scope)"), true)
            check("  no command, no id anywhere in the log (\(scope))",
                  e.slot.events.contains { $0.contains("SECRET_COMMAND_MARKER") || $0.contains("req-unique-77") || $0.contains("rm -rf") }, false)
        }

        print("center: the decision of a recap")
        e = Env()
        _ = e.offer(request("a"))
        e.unlock()
        e.center.click(requestID: "a", button: "deny")
        _ = await waitFor { !e.slot.decisions.isEmpty }
        check("a denied answer is recorded with the pill the card was shown with", e.slot.decisions.map { "\($0.pill):\($0.allow)" }, ["agent_hermes_alfred:false"])
    }

    // MARK: The slot is released from what it holds

    @MainActor
    static func slotRelease() async {
        print("center: agent removed while its card is shown")
        var e = Env()
        _ = e.offer(request("a")); _ = e.offer(request("b", agent: "mark"))
        e.slot.pills["alfred"] = nil
        e.center.agentRemoved("alfred")
        ok("  the card says it was withdrawn", e.center.withdrawn != nil)
        check("  the slot still holds it for the three seconds", e.slot.held, .hermes(key: "a", pill: "agent_hermes_alfred"))
        e.fireTimers()
        check("agent_removed_while_shown_releases_the_slot_from_the_stored_pill", e.slot.held, .hermes(key: "b", pill: "agent_hermes_mark"))
        ok("  the clear used the pill stored when the card was presented", e.slot.calls.contains("clear agent_hermes_alfred"))
        ok("  and the next request got the card", e.center.withdrawn == nil)
        e = Env()
        _ = e.offer(request("a"))
        e.slot.pills["alfred"] = nil
        e.center.agentRemoved("alfred")
        e.fireTimers()
        check("  with nobody waiting the slot is simply free", e.slot.held, nil)
        check("  and the island goes back to the overview and folds", [e.slot.view, "\(e.slot.collapses)"], ["overview", "1"])

        print("center: agent renamed while its card is shown")
        e = Env()
        _ = e.offer(request("a"))
        e.slot.pills["alfred"] = nil
        e.slot.pills["alfred2"] = "agent_hermes_alfred2"
        e.center.agentRemoved("alfred")
        e.fireTimers()
        check("agent_renamed_while_shown_releases_the_slot", e.slot.held, nil)

        print("center: a second agent whose name collides appears or goes while a card is shown")
        e = Env()
        _ = e.offer(request("a"))
        e.slot.pills["alfred"] = "agent_hermes_alfred_2"   // the pill id of the shown agent changed under the card
        e.unlock()
        e.center.click(requestID: "a", button: "once")
        check("click_releases_the_slot_even_when_the_pill_id_changed", e.slot.held, nil)
        _ = await waitFor { e.transport.answered.count == 1 }
        check("  the answer left once", e.transport.answered.count, 1)
        e = Env()
        _ = e.offer(request("a"))
        e.slot.pills["alfred"] = "agent_hermes_alfred_2"
        e.center.withdraw("a", .timeout)
        e.fireTimers()
        check("collision_while_a_withdrawn_card_is_shown_releases_the_slot", e.slot.held, nil)
        e = Env()
        _ = e.offer(request("a"))
        e.slot.pills["alfred"] = nil
        e.center.withdraw("a", .timeout)
        e.fireTimers()
        check("a withdrawn card whose agent is gone still releases the slot (every path of endWithdrawn)", e.slot.held, nil)

        print("center: withdrawn while shown, then the next card")
        e = Env()
        _ = e.offer(request("a")); _ = e.offer(request("b", agent: "mark"))
        e.center.withdraw("a", .timeout)
        check("  while the withdrawn card shows, no other card takes the slot", e.slot.held, .hermes(key: "a", pill: "agent_hermes_alfred"))
        check("  and nothing is presented over it", e.center.presentNextIfFree(), false)
        e.fireTimers()
        check("withdrawn_then_next_card: the next request is on screen", e.slot.held, .hermes(key: "b", pill: "agent_hermes_mark"))
        check("  the lock is armed for it", e.center.inputLocked, true)

        print("center: click on a card whose id left")
        e = Env()
        _ = e.offer(request("a")); _ = e.offer(request("b", agent: "mark"))
        e.center.withdraw("a", .resolved)
        e.unlock()
        e.center.click(requestID: "a", button: "once")
        e.center.click(requestID: "b", button: "once")   // b is not shown yet: the withdrawn card holds the slot
        await settle()
        check("click_on_a_card_whose_id_left_sends_nothing (withdrawn, and the next not shown yet)", e.transport.answered.count, 0)
        e.fireTimers()
        e.unlock()
        e.center.click(requestID: "a", button: "once")
        await settle()
        check("  and the old id is still dead when the next card is up", e.transport.answered.count, 0)
    }

    // MARK: Hook cards over Hermes cards

    @MainActor
    static func hookCards() async {
        print("center: a hook card over a shown card, and the way back")
        var e = Env()
        _ = e.offer(request("a"))
        e.center.select(.session, requestID: "a")   // locked still: the selector does not move
        e.unlock()
        e.center.select(.session, requestID: "a")
        check("  the selector moved", e.center.queue.scope, .session)
        e.slot.hookCardArrives()
        check("hook_over_shown: the request waits again, nothing was sent", e.transport.answered.count, 0)
        check("  the slot is the hook's", e.slot.held, .hook)
        check("  the selector is back on once", e.center.queue.scope, .once)
        ok("  the pill carries the badge", e.slot.badges.contains("agent_hermes_alfred"))
        e.now += 5
        e.center.click(requestID: "a", button: "once")
        await settle()
        check("  a click on the hidden card sends nothing", e.transport.answered.count, 0)
        e.slot.hookCardLeaves()
        check("hook_way_back: the same request is on screen again", e.slot.held, .hermes(key: "a", pill: "agent_hermes_alfred"))
        ok("  without the sound twice", e.slot.calls.filter { $0.hasPrefix("present a") }.map { $0.hasSuffix("sound=true") } == [true, false])
        check("  with the lock armed again", e.center.inputLocked, true)

        print("center: a hook card over a withdrawn card")
        e = Env()
        _ = e.offer(request("a")); _ = e.offer(request("b", agent: "mark"))
        e.center.withdraw("a", .timeout)
        e.slot.hookCardArrives()
        ok("hook_over_withdrawn: the withdrawn card is gone", e.center.withdrawn == nil)
        e.fireTimers()
        check("  the old timer does not touch the hook card", e.slot.held, .hook)
        ok("  nothing cleared it", !e.slot.calls.contains { $0.hasPrefix("clear") })
        e.slot.hookCardLeaves()
        check("hook_over_withdrawn_way_back: the next request comes up", e.slot.held, .hermes(key: "b", pill: "agent_hermes_mark"))
        check("  nothing was answered", e.transport.answered.count, 0)
    }

    // MARK: The input lock

    @MainActor
    static func inputLock() async {
        print("center: every Hermes card arms the input lock")
        var e = Env()
        _ = e.offer(request("a"))
        e.center.click(requestID: "a", button: "once")
        await settle()
        check("first_card_on_an_empty_screen_ignores_a_click_for_a_moment", e.transport.answered.count, 0)
        e.center.select(.always, requestID: "a")
        check("  the selector too", e.center.queue.scope, .once)
        e.center.setReading(true, requestID: "a")
        check("  and the See whole command toggle", e.center.reading, false)
        e.now += 0.69
        check("  still locked at 0.69 s", e.center.inputLocked, true)
        e.now += 0.02
        check("  free at 0.71 s", e.center.inputLocked, false)
        e.center.click(requestID: "a", button: "once")
        check("  then the click goes", await waitFor { e.transport.answered.count == 1 }, true)

        print("center: two cards in turn")
        e = Env()
        _ = e.offer(request("a")); _ = e.offer(request("b"))
        e.unlock()
        e.center.click(requestID: "a", button: "once")
        check("two_cards_in_turn: the second is on screen", e.slot.held, .hermes(key: "b", pill: "agent_hermes_alfred"))
        e.center.click(requestID: "b", button: "once")
        await settle()
        check("  a click aimed at the first lands on the second and is ignored", e.transport.answered.map(\.id), ["a"])
        e.now += 0.8
        e.center.click(requestID: "b", button: "deny")
        check("  after the lock the second can be answered", await waitFor { e.transport.answered.count == 2 }, true)

        print("center: a re-offered card")
        e = Env()
        _ = e.offer(request("a"))
        e.unlock()
        e.center.click(requestID: "a", button: "once")
        e.transport.outcome = .failed
        _ = await waitFor { e.transport.answered.count == 1 }
        _ = await waitFor { e.center.queue.entries.isEmpty }
        check("  the failed answer left the queue", e.center.queue.entries.isEmpty, true)
        ok("a_re_offered_request_is_a_new_card: offered again", e.offer(request("a")))
        e.center.click(requestID: "a", button: "once")
        await settle()
        check("  and locked like any card", e.transport.answered.count, 1)
        e.unlock()
        e.center.click(requestID: "a", button: "once")
        check("  free a moment later", await waitFor { e.transport.answered.count == 2 }, true)
    }

    // MARK: The island on the way out

    @MainActor
    static func islandReturn() async {
        print("center: the result note")
        var e = Env()
        e.transport.gateOpen = false
        _ = e.offer(request("a"))
        e.unlock()
        e.center.click(requestID: "a", button: "once")
        check("  the card left the island for the overview", e.slot.view, "overview")
        e.transport.gateOpen = true
        _ = await waitFor { !e.slot.notes.isEmpty }
        check("a result that arrives while the island still shows what the card left is a note", e.slot.notes, [HA.answerNote(.once)])

        e = Env()
        e.transport.gateOpen = false
        _ = e.offer(request("a"))
        e.unlock()
        e.center.click(requestID: "a", button: "once")
        e.slot.view = "mail"          // the owner moved on while the answer was on its way
        e.transport.gateOpen = true
        _ = await waitFor { e.slot.events.contains { $0.hasPrefix("answered") } }
        check("the_note_does_not_take_the_island_when_the_view_changed", e.slot.notes, [])
        check("  and the owner's view was not replaced", e.slot.view, "mail")

        print("center: back to the chat")
        e = Env()
        e.slot.view = "prompt"
        _ = e.offer(request("a"))
        e.unlock()
        e.center.click(requestID: "a", button: "once")
        check("a card that came from the chat goes back to the chat", e.slot.view, "prompt")

        print("center: the way back is forgotten when the queue empties")
        e = Env()
        e.slot.view = "prompt"
        _ = e.offer(request("a"))
        e.slot.hookCardArrives()
        e.center.withdraw("a", .timeout)   // withdrawn while queued behind the hook card
        e.slot.hookCardLeaves()
        e.slot.view = "overview"
        _ = e.offer(request("b"))
        e.unlock()
        e.center.click(requestID: "b", button: "once")
        check("view_before_card_is_reset_when_the_queue_empties: a later card goes to the overview, not the old chat", e.slot.view, "overview")

        print("center: badges")
        e = Env()
        _ = e.offer(request("a"))
        _ = e.offer(request("b", agent: "mark"))
        ok("  the waiting agent's pill carries the badge", e.slot.badges.contains("agent_hermes_mark"))
        e.center.withdraw("b", .timeout)
        check("queued_withdrawal_clears_the_badge", e.slot.badges.contains("agent_hermes_mark"), false)
        _ = e.offer(request("c", agent: "mark"))
        e.center.turnEnded(1, .turnEnded)
        e.fireTimers()
        check("a turn that ends clears the badges of its queued requests", e.slot.badges.isEmpty, true)
    }

    // MARK: A share of the line per agent

    @MainActor
    static func queueShare() async {
        print("center: one agent cannot fill the line")
        let e = Env()
        var taken = 0
        for i in 1...6 { if e.offer(request("a\(i)")) { taken += 1 } }
        check("per_agent_share_is_four_of_eight: alfred is offered six, four are taken", taken, 4)
        ok("  another agent still gets in", e.offer(request("m1", agent: "mark")))
        for i in 2...5 { _ = e.offer(request("m\(i)", agent: "mark")) }
        check("  the line holds eight in all", e.center.queue.entries.count, 8)
    }

    // MARK: Round 3: the clock of the lock, the pill of a card that left, the reading flow

    @MainActor
    static func clockAndPills() async {
        print("center: the lock reads a monotonic clock (Aegis N4)")
        let before = ProcessInfo.processInfo.systemUptime
        let center = HermesApprovalCenter(slot: FakeSlot())
        let read = center.clock()
        let after = ProcessInfo.processInfo.systemUptime
        ok("the default clock of the center is system uptime, not the wall clock", read >= before && read <= after)
        ok("  (the wall clock reads about \(Int(Date().timeIntervalSinceReferenceDate)), uptime \(Int(read)))", abs(Date().timeIntervalSinceReferenceDate - read) > 1000)
        var e = Env()
        _ = e.offer(request("a"))
        e.now += 0.3
        e.now -= 5           // the clock steps back
        check("clock_stepping_back_does_not_unlock", e.center.inputLocked, true)
        e.center.click(requestID: "a", button: "once")
        await settle()
        check("  a click right after the step back sends nothing", e.transport.answered.count, 0)
        e.now += 0.69
        check("  the window restarts from the step: still locked 0.69 s later", e.center.inputLocked, true)
        e.now += 0.02
        check("  free 0.71 s after it", e.center.inputLocked, false)
        e.center.click(requestID: "a", button: "once")
        check("  and then the click goes", await waitFor { e.transport.answered.count == 1 }, true)
        var armed: TimeInterval? = 100
        check("lock helper: step back while armed is locked", CardInputLock.isLockedKeepingWindow(armedAt: &armed, now: 40), true)
        check("  and never longer than the delay after the step", CardInputLock.isLockedKeepingWindow(armedAt: &armed, now: 40.71), false)
        var none: TimeInterval? = nil
        check("  nothing armed: not locked", CardInputLock.isLockedKeepingWindow(armedAt: &none, now: 5), false)
        check("hook cards keep their own rule (wall clock semantics unchanged)", CardInputLock.isLocked(armedAt: 100, now: 40), false)

        print("center: a pill never keeps the needs permission look with no card (Hera minor 1)")
        e = Env()
        _ = e.offer(request("a"))
        e.slot.hookCardArrives()
        e.center.withdraw("a", .timeout)
        check("pill_reset_when_a_shown_request_is_withdrawn_behind_a_hook_card", e.slot.calls.filter { $0 == "pill-after agent_hermes_alfred" }.count, 1)
        e = Env()
        _ = e.offer(request("a")); _ = e.offer(request("b", agent: "mark"))
        e.center.withdraw("b", .timeout)
        check("a request that was never shown has no pill to reset", e.slot.calls.contains { $0 == "pill-after agent_hermes_mark" }, false)
        e = Env()
        _ = e.offer(request("a"))
        e.slot.hookCardArrives()
        e.center.turnEnded(1, .turnEnded)
        check("pill_reset_when_the_turn_ends_behind_a_hook_card", e.slot.calls.filter { $0 == "pill-after agent_hermes_alfred" }.count, 1)
        e = Env()
        _ = e.offer(request("a"))
        e.slot.hookCardArrives()
        e.center.retain(["zzz"], known: ["a"], turn: 1)
        check("pill_reset_when_the_server_no_longer_lists_it", e.slot.calls.filter { $0 == "pill-after agent_hermes_alfred" }.count, 1)
        e = Env()
        _ = e.offer(request("a"))
        e.slot.hookCardArrives()
        e.slot.pills["alfred"] = nil
        e.center.agentRemoved("alfred")
        check("pill_reset_when_the_agent_is_removed_behind_a_hook_card (by the pill it was shown with)", e.slot.calls.contains("pill-after agent_hermes_alfred"), true)
        e = Env()
        _ = e.offer(request("a"))
        e.slot.hookCardArrives()
        e.center.withdraw("a", .timeout)
        e.slot.hookCardLeaves()
        e.center.withdraw("a", .timeout)
        check("  twice is still once", e.slot.calls.filter { $0 == "pill-after agent_hermes_alfred" }.count, 1)
        e = Env()
        _ = e.offer(request("a")); _ = e.offer(request("a2"))
        e.slot.hookCardArrives()
        e.slot.hookCardLeaves()          // a is back on screen, a2 waits
        e.center.withdraw("a2", .timeout)
        check("a card of the same pill on screen keeps the look", e.slot.calls.contains("pill-after agent_hermes_alfred"), false)
        e.unlock()
        e.center.click(requestID: "a", button: "once")
        check("an answered request does not reset it twice", e.slot.calls.contains("pill-after agent_hermes_alfred"), false)
    }

    @MainActor
    static func readingFlow() async {
        let long = "echo one\necho two\necho three"
        print("center: a click needs the id in the slot (Hera minor 3)")
        var e = Env()
        _ = e.offer(request("a"))
        e.unlock()
        e.slot.held = .hook          // the slot lost the Hermes card and the center was not told
        e.center.click(requestID: "a", button: "once")
        await settle()
        check("click_needs_the_shown_id_to_be_the_one_in_the_slot: a hook card in the slot", e.transport.answered.count, 0)
        e.slot.held = .hermes(key: "other", pill: "agent_hermes_alfred")
        e.center.click(requestID: "a", button: "deny")
        await settle()
        check("  another Hermes card in the slot, even a deny", e.transport.answered.count, 0)
        e.slot.held = .hermes(key: "a", pill: "agent_hermes_alfred")
        e.center.click(requestID: "a", button: "deny")
        check("  the right id goes", await waitFor { e.transport.answered.count == 1 }, true)

        print("center: the reading flow of a long command")
        e = Env()
        _ = e.offer(request("a", command: long))
        e.unlock()
        e.center.click(requestID: "a", button: "once")
        await settle()
        check("reading_flow: Allow on the closed card is refused", e.transport.answered.count, 0)
        e.center.setReading(true, requestID: "a")
        ok("  the reading view opened", e.center.reading)
        e.center.click(requestID: "a", button: "once")
        await settle()
        check("  Allow before the end of the text is refused", e.transport.answered.count, 0)
        e.slot.hookCardArrives()
        e.slot.hookCardLeaves()
        e.unlock()
        e.center.setReading(true, requestID: "a")
        e.center.reachedEnd(requestID: "a")
        e.slot.hookCardArrives()
        e.slot.hookCardLeaves()
        e.unlock()
        e.center.setReading(true, requestID: "a")
        e.center.click(requestID: "a", button: "once")
        await settle()
        check("  the end flag is reset after a hook card and back: Allow is refused again", e.transport.answered.count, 0)
        e.center.reachedEnd(requestID: "a")
        e.center.click(requestID: "a", button: "once")
        check("  Allow after the end is sent", await waitFor { e.transport.answered.count == 1 }, true)

        e = Env()
        _ = e.offer(request("a", command: long))
        e.unlock()
        e.center.setReading(true, requestID: "a")
        e.center.reachedEnd(requestID: "a")
        e.center.setReading(false, requestID: "a")
        e.center.click(requestID: "a", button: "once")
        await settle()
        check("allow_on_a_closed_card_read_once_and_folded_is_refused", e.transport.answered.count, 0)
        e.center.click(requestID: "a", button: "deny")
        check("  Deny on the closed card always goes", await waitFor { e.transport.answered.count == 1 }, true)
    }
}
