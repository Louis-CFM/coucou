import SwiftUI

// MARK: - The Hermes approvals in the app: the card slot, the model of the card and the view that hosts it
//
// `HermesApprovalCenter` decides; this file is the screen it decides on (AppState, HookServer, the pills).

/// The slot of the app. Every method forwards to `AppState` or `HookServer`; no decision is taken here.
@MainActor
final class AppHermesSlot: HermesCardSlot {
    private var state: AppState { AppState.shared }

    var isFree: Bool { HookServer.shared.hermesSlotFree }
    var noCardShown: Bool { state.pendingApproval == nil && state.pendingQuestion == nil }
    var shownInputKey: String? { state.pendingApproval?.inputKey }
    var shownPillId: String? { state.pendingApproval?.pillId }
    var chatOnScreen: Bool { state.view == .prompt }
    var viewMarker: String { state.view.rawValue }

    func pillId(forAgent name: String) -> String? {
        HermesPills.taskIds(for: state.hermesAgents.map { $0.name })[name]
    }

    func present(_ request: HermesApprovalRequest, pillId: String, playSound: Bool) {
        HookServer.shared.presentHermesCard(request: request, pillId: pillId, playSound: playSound)
    }

    func clear(pillId: String, agent: String) { HookServer.shared.clearHermesCard(pillId: pillId, agent: agent) }

    func presentNextAfterHermesCard() -> Bool { HookServer.shared.presentNextAfterHermesCard() }

    func setReadingHeight(_ height: CGFloat?) { state.approvalReadingHeight = height }

    func setWaitingBadge(pillId: String) { state.setPillBadge(.approval, for: pillId) }

    func clearWaitingBadges(keeping keep: Set<String>) {
        let stale = state.tasks.filter { HermesPills.isTaskId($0.id) && $0.pillBadge == .approval && !keep.contains($0.id) }.map(\.id)
        for id in stale { if let i = state.tasks.firstIndex(where: { $0.id == id }) { state.tasks[i].pillBadge = nil } }
    }

    func setPillAfterCard(pillId: String, agent: String) {
        state.updateTask(id: pillId, state: (state.hermesTurnsRunning[agent] ?? 0) > 0 ? .thinking : .idle)
    }

    func recordDecision(pillId: String, allow: Bool) {
        RecapStore.shared.recordDecision(pillId: pillId, decision: allow ? "allow" : "deny")
    }

    func returnToChat() -> Bool {
        guard state.mode == .expanded else { return false }
        state.view = .prompt
        return true
    }

    func showOverview() { state.view = state.tasks.isEmpty ? .empty : .overview }

    func showNote(_ text: String) {
        state.noteMessage = text
        state.view = .note
        collapseLater(after: 3)
    }

    func collapse() { collapseLater(after: 0) }

    private func collapseLater(after seconds: Double) {
        let fire = {
            if AppState.shared.hermesAnnounceHoldsIsland { return }
            NotificationCenter.default.post(name: .islandCollapse, object: nil)
        }
        if seconds > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: fire) } else { DispatchQueue.main.async(execute: fire) }
    }

    func log(_ event: String) { appendAppLog("nb.log", "hermes approval " + event) }
}

extension HermesApprovalCenter {
    static let shared = HermesApprovalCenter(slot: AppHermesSlot())

    static var hooks: HermesApprovalHooks {
        HermesApprovalHooks(
            offer: { request, turn, answer in HermesApprovalCenter.shared.offer(request, turn: turn, answer: answer) },
            withdrawn: { id, reason in HermesApprovalCenter.shared.withdraw(id, reason) },
            retain: { ids, known, turn in HermesApprovalCenter.shared.retain(ids, known: known, turn: turn) },
            turnEnded: { turn, reason in HermesApprovalCenter.shared.turnEnded(turn, reason) })
    }

    // MARK: What the card draws

    private func task(of agentName: String) -> AgentTask? {
        guard let id = slot.pillId(forAgent: agentName) else { return nil }
        return AppState.shared.tasks.first { $0.id == id }
    }

    var cardModel: HermesApprovalCardModel? {
        if let w = withdrawn {
            return HermesApprovalCardModel(task: task(of: w.request.agentName), requestID: w.request.requestID, display: w.display,
                                           choices: [], scope: .once, waitingBehind: queue.waitingBehind, reading: false,
                                           reachedEnd: false, withdrawn: w.sentence)
        }
        guard let e = queue.shown, slot.shownInputKey == e.request.requestID else { return nil }
        return HermesApprovalCardModel(task: task(of: e.request.agentName), requestID: e.request.requestID, display: e.display,
                                       choices: e.request.offered, scope: queue.scope, waitingBehind: queue.waitingBehind,
                                       reading: reading, reachedEnd: e.reachedEnd, withdrawn: nil,
                                       grant: e.request.grantLabel, masked: e.request.masked)
    }
}

/// What `ApprovalView` shows for a Hermes pill. Reads the center; the buttons go back to it through `HookServer`,
/// which holds the input lock of a card that replaced another.
struct HermesApprovalHost: View {
    @ObservedObject var state: AppState
    @ObservedObject private var center = HermesApprovalCenter.shared

    var body: some View {
        if let model = center.cardModel {
            let id = model.requestID
            HermesApprovalCard(model: model, actions: HermesApprovalCardActions(
                answer: { HookServer.shared.sendHermesDecision(requestID: id, button: $0) },
                select: { center.select($0, requestID: id) },
                setReading: { center.setReading($0, requestID: id) },
                reachedEnd: { center.reachedEnd(requestID: id) }))
        } else {
            CardBackground(wash: .amber)
        }
    }
}
