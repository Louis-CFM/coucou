import Combine
import Foundation

/// Height of the island while the whole text of a long command is read. Read by the nonisolated `islandSize`;
/// written on the main actor only.
enum ApprovalReadingLayout {
    nonisolated(unsafe) static var height: CGFloat?
    static let readingHeight: CGFloat = 340
}

/// What the center needs from the screen: the card slot it shares with the hook approvals and the cmux questions, the pills,
/// the island views and the log. The app implements it with `AppState` and `HookServer` (HermesApprovalSlot.swift); a test
/// implements it with a fake that records what the center asks, so the decisions below run without the app.
///
/// Nothing in this protocol answers a request: an answer exists only as the result of `HermesApprovalCenter.click`.
@MainActor
protocol HermesCardSlot: AnyObject {
    /// No approval and no question holds the card slot (a demo card does not count).
    var isFree: Bool { get }
    /// No approval and no question is shown at all.
    var noCardShown: Bool { get }
    /// The request id and the pill of the approval card the slot holds now, nil when it holds none.
    var shownInputKey: String? { get }
    var shownPillId: String? { get }
    /// The island shows the Hermes chat.
    var chatOnScreen: Bool { get }
    /// Names the view on the island; two equal values are the same view.
    var viewMarker: String { get }

    /// The pill of the agent with this identity name, nil when the agent is gone.
    func pillId(forAgent name: String) -> String?
    func present(_ request: HermesApprovalRequest, pillId: String, playSound: Bool)
    /// Takes the Hermes card of `pillId` out of the slot. A no-op when the slot holds another card.
    func clear(pillId: String, agent: String)
    /// The slot is free again: the cmux queue first, then the next Hermes request. True when a card appeared.
    func presentNextAfterHermesCard() -> Bool
    func setReadingHeight(_ height: CGFloat?)
    func setWaitingBadge(pillId: String)
    /// Takes the approval badge off every Hermes pill that is not in `keep`.
    func clearWaitingBadges(keeping keep: Set<String>)
    func setPillAfterCard(pillId: String, agent: String)
    func recordDecision(pillId: String, allow: Bool)
    /// True when the island went back to the chat.
    func returnToChat() -> Bool
    func showOverview()
    func showNote(_ text: String)
    func collapse()
    func log(_ event: String)
}

/// The Hermes approvals on the screen of the notch: it owns the queue, takes the requests the transports offer, puts one
/// at a time in the card slot, and sends an answer only after a click on a button of that card.
///
/// Never here: an answer without a click, a default, a timer that answers. The timers below only remove a card.
@MainActor
final class HermesApprovalCenter: ObservableObject {
    @Published private(set) var queue = HermesApprovalQueue()
    @Published private(set) var reading = false
    /// Hermes withdrew the request on screen: the card says so for three seconds and offers nothing.
    @Published private(set) var withdrawn: Withdrawn?

    struct Withdrawn: Equatable {
        var request: HermesApprovalRequest
        var display: HermesApprovalDisplay
        var sentence: String
        var token: Int
        /// The pill the card was presented with: what the slot holds, kept so the slot is released from it.
        var pill: String?
    }

    enum Origin { case chat, other }

    let slot: HermesCardSlot
    /// The clock of the input lock: system uptime, which never steps back. A test replaces it and moves it by hand.
    var clock: () -> TimeInterval = { CardInputLock.uptime }
    /// Runs `body` when the withdrawn card has been on screen for three seconds. A test keeps it and runs it by hand.
    var afterWithdrawn: (@escaping @MainActor () -> Void) -> Void = { body in
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { body() } }
    }

    /// The way back to the transport that asked, by request id. Used only by `click`.
    private var answers: [String: HermesApprovalAnswer] = [:]
    /// The pill each answer in flight was presented with, and the view the island showed when its card left.
    private var answerPills: [String: String] = [:]
    private var leftViews: [String: String] = [:]
    /// The pill of the card in the slot, stored when it was presented. Every release of the slot uses this, never a lookup
    /// that the list of agents can make fail.
    private(set) var shownPill: String?
    /// The pill and agent of every request that was presented and has not left yet (answered or withdrawn on screen). A request
    /// of this list that leaves the line while it waits again behind a hook card has no card to end its pill's look.
    private var presentedPills: [String: (pill: String, agent: String)] = [:]
    /// What was on the island before the first card: the Hermes chat goes back to the chat, the rest to the overview.
    private var origin: Origin?
    private var withdrawnToken = 0
    /// Every Hermes card that is presented arms the input lock, whatever was on screen before it.
    private var lockArmedAt: TimeInterval?

    init(slot: HermesCardSlot) { self.slot = slot }

    var hasWaiting: Bool { queue.hasWaiting || withdrawn != nil }

    var inputLocked: Bool { CardInputLock.isLockedKeepingWindow(armedAt: &lockArmedAt, now: clock()) }

    // MARK: Requests

    /// A transport parsed a request. True when the center took it: a card will show it (now or later) and it is answered
    /// only after a click. False leaves it to Hermes (the transport writes its one sentence).
    func offer(_ request: HermesApprovalRequest, turn: Int, answer: @escaping HermesApprovalAnswer) -> Bool {
        guard slot.pillId(forAgent: request.agentName) != nil else { return false }
        guard queue.add(request, display: HermesApproval.display(request.command), turn: turn) == .queued else { return false }
        answers[request.requestID] = answer
        slot.log("received")
        if !presentNextIfFree() { markWaiting(agent: request.agentName) }
        return true
    }

    /// A request waits for the slot: its pill carries the approval badge.
    private func markWaiting(agent: String) {
        if let id = slot.pillId(forAgent: agent) { slot.setWaitingBadge(pillId: id) }
    }

    /// Puts the next waiting request in the card slot, when the slot is free. Every card that appears ignores clicks for a
    /// moment (`CardInputLock`): a click aimed at what was on screen before cannot land on it. That holds for the first card
    /// on an empty screen, for a card promoted from the line and for a request offered again.
    @discardableResult
    func presentNextIfFree() -> Bool {
        guard withdrawn == nil, slot.isFree else { return false }
        while let p = queue.promoteNext() {
            guard let pill = slot.pillId(forAgent: p.request.agentName) else {
                _ = queue.withdraw(p.request.requestID)
                answers[p.request.requestID] = nil
                continue
            }
            if origin == nil { origin = slot.chatOnScreen ? .chat : .other }
            reading = false
            slot.setReadingHeight(nil)
            shownPill = pill
            presentedPills[p.request.requestID] = (pill, p.request.agentName)
            lockArmedAt = CardInputLock.armedAt(cardWasVisible: true, now: clock())
            slot.present(p.request, pillId: pill, playSound: p.playSound)
            slot.log("shown")
            return true
        }
        return false
    }

    /// Another card (a hook approval or question) is about to take the slot: the shown request waits again, at the head.
    /// Nothing is sent to Hermes.
    func requeueIfShowing() {
        if withdrawn != nil { withdrawn = nil }
        shownPill = nil
        guard let shown = queue.shown else { return }
        queue.requeueShown()
        reading = false
        slot.setReadingHeight(nil)
        markWaiting(agent: shown.request.agentName)
    }

    // MARK: The card's buttons

    func select(_ scope: HermesApproval.Scope, requestID: String) {
        guard !inputLocked, queue.shownID == requestID, withdrawn == nil else { return }
        queue.select(scope)
    }

    func setReading(_ on: Bool, requestID: String) {
        guard !inputLocked, let shown = queue.shown, shown.request.requestID == requestID, withdrawn == nil else { return }
        if on {
            guard shown.display.tier == .reading else { return }
            reading = true
            slot.setReadingHeight(ApprovalReadingLayout.readingHeight)
        } else {
            reading = false
            slot.setReadingHeight(nil)
        }
    }

    /// The reading view had the last line on screen.
    func reachedEnd(requestID: String) {
        guard reading, let shown = queue.shown, shown.request.requestID == requestID, !shown.reachedEnd else { return }
        queue.markReachedEnd(requestID)
    }

    /// An explicit click on a button of the card of `requestID` (after `HookServer` checked the slot's input lock).
    /// The only place an answer is born.
    func click(requestID: String, button: String) {
        guard !inputLocked, withdrawn == nil, let shown = queue.shown, shown.request.requestID == requestID,
              slot.shownInputKey == requestID,
              let choice = HermesApproval.decision(for: button, request: shown.request),
              // A long command is allowed from the reading view only: the closed card has no Allow, so a click on one that was
              // read once and then folded is not an answer either.
              choice == .deny || shown.display.tier != .reading || reading,
              let pill = shownPill ?? slot.shownPillId,
              let answer = answers[requestID],
              case .send(let request, let sent) = queue.click(choice, id: requestID) else { return }
        answerPills[requestID] = pill
        presentedPills[requestID] = nil
        reading = false
        slot.clear(pillId: pill, agent: request.agentName)
        shownPill = nil
        if slot.presentNextAfterHermesCard() {
            leftViews[requestID] = nil
        } else {
            leaveIsland()
            leftViews[requestID] = slot.viewMarker
        }
        settle()
        slot.log("answer sent scope=\(sent.rawValue)")
        Task { @MainActor in
            let outcome = await answer(sent)
            self.answered(request, sent, outcome)
        }
    }

    private func answered(_ request: HermesApprovalRequest, _ choice: HermesApproval.Choice, _ outcome: HermesApproval.AnswerOutcome) {
        let id = request.requestID
        queue.finish(id)
        answers[id] = nil
        let pill = answerPills.removeValue(forKey: id)
        let left = leftViews.removeValue(forKey: id)
        slot.log("answered outcome=\(outcome)")
        if outcome == .applied, let pill { slot.recordDecision(pillId: pill, allow: choice != .deny) }
        settle()
        // The result as a note for three seconds, only when nothing else holds the island and it still shows the view this
        // card left (the answer can come up to 30 s after the click: by then the owner may be elsewhere). The chat keeps
        // its own row.
        guard slot.noCardShown, !queue.hasWaiting, withdrawn == nil, !slot.chatOnScreen,
              let left, slot.viewMarker == left else { return }
        slot.showNote(HermesApproval.outcomeNote(choice: choice, outcome: outcome))
    }

    // MARK: Withdrawals

    func withdraw(_ id: String, _ reason: HermesApproval.WithdrawReason) {
        switch queue.withdraw(id) {
        case .none: break
        case .droppedQueued:
            answers[id] = nil
            clearStaleBadges()
            resetPills(of: [id])
        case .endedShown(let request): showWithdrawn(request, reason)
        }
        settle()
    }

    func retain(_ ids: Set<String>, known: Set<String>, turn: Int) {
        apply(queue.retain(ids: ids, knownBefore: known, turn: turn), .stale)
    }

    func turnEnded(_ turn: Int, _ reason: HermesApproval.WithdrawReason) {
        apply(queue.withdrawAll(turn: turn), reason)
    }

    func agentRemoved(_ name: String) {
        apply(queue.withdrawAll(agent: name), .agentRemoved)
    }

    private func apply(_ w: HermesApprovalQueue.Withdrawal, _ reason: HermesApproval.WithdrawReason) {
        for id in w.ids { answers[id] = nil }
        if let shown = w.endedShown { showWithdrawn(shown, reason) }
        if w.dropped > 0 { clearStaleBadges() }
        resetPills(of: w.ids)
        settle()
    }

    /// A request that was shown once and left the line while it waited (withdrawn behind a hook card, its turn ended, its agent
    /// removed) takes its pill off the "needs permission" look, unless a card of that pill is on screen.
    private func resetPills(of ids: [String]) {
        for id in ids {
            guard let p = presentedPills.removeValue(forKey: id) else { continue }
            if queue.shown != nil, shownPill == p.pill { continue }
            slot.setPillAfterCard(pillId: p.pill, agent: p.agent)
        }
    }

    /// The approval badge stays only on the pills of agents that still have a request waiting.
    private func clearStaleBadges() {
        let waiting = Set(queue.entries.filter { $0.phase != .answering }.compactMap { slot.pillId(forAgent: $0.request.agentName) })
        slot.clearWaitingBadges(keeping: waiting)
    }

    /// The request on screen is gone: the card says so and offers nothing, then it leaves.
    private func showWithdrawn(_ request: HermesApprovalRequest, _ reason: HermesApproval.WithdrawReason) {
        answers[request.requestID] = nil
        presentedPills[request.requestID] = nil
        reading = false
        slot.setReadingHeight(nil)
        withdrawnToken += 1
        let token = withdrawnToken
        let pill = shownPill
        withdrawn = Withdrawn(request: request, display: HermesApproval.display(request.command),
                              sentence: HermesApproval.note(for: reason), token: token, pill: pill)
        // The card says it is over: Mochi leaves the "needs permission" look, the card stays for its three seconds.
        if let pill { slot.setPillAfterCard(pillId: pill, agent: request.agentName) }
        slot.log("withdrawn")
        afterWithdrawn { [weak self] in self?.endWithdrawn(token) }
    }

    /// The three seconds are over: the slot is released from what it holds, whatever became of the agent.
    func endWithdrawn(_ token: Int) {
        guard let w = withdrawn, w.token == token else { return }
        withdrawn = nil
        if let pill = w.pill ?? shownPill { slot.clear(pillId: pill, agent: w.request.agentName) }
        shownPill = nil
        if slot.presentNextAfterHermesCard() { return }
        if leaveIsland() { settle(); return }
        settle()
        slot.collapse()
    }

    // MARK: Leaving the island

    /// No card holds the slot any more: back to the chat the card came from, else the overview.
    /// True when it went back to the chat.
    @discardableResult
    private func leaveIsland() -> Bool {
        guard slot.noCardShown else { return false }
        let from = origin
        origin = nil
        if from == .chat, slot.returnToChat() { return true }
        slot.showOverview()
        return false
    }

    /// Nothing waits for the slot any more: the view the first card came from is forgotten, so a card minutes later does
    /// not send the island back to a chat the owner left.
    private func settle() {
        if !queue.hasWaiting && withdrawn == nil { origin = nil }
    }
}
