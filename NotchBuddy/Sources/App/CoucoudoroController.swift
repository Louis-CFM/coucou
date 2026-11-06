import Combine
import Foundation

/// Coucoudoro: work, then rest, then work again, until the user stops.
/// The session is a deadline. One timer fires at that deadline (nothing ticks in between, so
/// Coucou stays at 0 % CPU while hidden); the card and the pill draw the clock from the deadline.
@MainActor
final class CoucoudoroController: ObservableObject {
    static let shared = CoucoudoroController()
    nonisolated static let pillId = CoucoudoroSettings.pillId

    @Published private(set) var phase: CoucoudoroPhase = .idle
    @Published private(set) var paused = false
    @Published private(set) var deadline: Date?
    @Published private(set) var pausedRemaining: TimeInterval?
    @Published private(set) var notice: CoucoudoroEvent?
    /// The pill capsule shows `notice` until this instant, then the clock again.
    @Published private(set) var noticeUntil: Date?

    private var snap = CoucoudoroSnapshot.idle
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private var isPillActive: Bool {
        AppState.shared.activeIntegrations.contains(Self.pillId)
    }

    private init() {
        AppState.shared.$activeIntegrations
            .map { $0.contains(Self.pillId) }
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updatePolling() }
            }
            .store(in: &cancellables)
    }

    func start() { updatePolling() }

    /// Lengths apply to the next phase. The phase already running keeps its deadline.
    func settingsChanged() {
        guard snap.phase != .idle, !snap.paused else { return }
        tick()
    }

    func begin() {
        guard isPillActive else { return }
        let (next, events) = CoucoudoroEngine.start(config: CoucoudoroSettings.config, now: Date())
        snap = next
        publish()
        ensureTimer()
        if let last = events.last { surface(last) }
    }

    /// End the session. The next begin() is a fresh work phase.
    func end() {
        snap = CoucoudoroEngine.stop()
        noticeUntil = nil
        publish()
        stopTimer()
        paintIdle()
    }

    func pause() {
        guard isPillActive, snap.phase != .idle, !snap.paused else { return }
        snap = CoucoudoroEngine.pause(snap, now: Date())
        publish()
        stopTimer()
        paint(state: .idle, steps: [String(localized: "coucoudoro.paused", defaultValue: "Paused")])
    }

    func resume() {
        guard isPillActive, snap.paused else { return }
        snap = CoucoudoroEngine.resume(snap, now: Date())
        publish()
        ensureTimer()
        let copy = snap.notice.map(Self.text(for:)) ?? String(localized: "coucoudoro.work", defaultValue: "Work")
        paint(state: snap.phase == .work ? .working : .idle, steps: [copy])
        tick()
    }

    func remaining(at date: Date) -> TimeInterval? {
        if paused { return pausedRemaining }
        guard phase != .idle, let deadline else { return nil }
        return max(0, deadline.timeIntervalSince(date))
    }

    /// The sentence on the pill. A phase change names the phase that just started, for a few seconds.
    func banner(at date: Date) -> String? {
        guard let notice, let until = noticeUntil, date < until else { return nil }
        switch notice {
        case .restStarts:
            return String(localized: "coucoudoro.pill.rest", defaultValue: "Coucoudoro · Rest")
        case .workStarts:
            return String(localized: "coucoudoro.pill.work", defaultValue: "Coucoudoro · Work")
        }
    }

    /// What the pill capsule says: the sentence while it is fresh, otherwise the clock.
    func pillLabel(at date: Date) -> String {
        if let banner = banner(at: date) { return banner }
        if phase != .idle, let left = remaining(at: date) {
            return CoucoudoroEngine.clock(left)
        }
        return "Coucoudoro"
    }

    static func text(for event: CoucoudoroEvent) -> String {
        switch event {
        case .restStarts: String(localized: "coucoudoro.pill.rest", defaultValue: "Coucoudoro · Rest")
        case .workStarts: String(localized: "coucoudoro.pill.work", defaultValue: "Coucoudoro · Work")
        }
    }

    // MARK: - Clock

    private func updatePolling() {
        if isPillActive {
            if snap.phase != .idle, !snap.paused { ensureTimer() }
        } else if snap.phase != .idle || timer != nil {
            snap = CoucoudoroEngine.stop()
            noticeUntil = nil
            publish()
            stopTimer()
            paintIdle()
        }
    }

    /// One timer, at the running phase's deadline.
    private func ensureTimer() {
        timer?.invalidate()
        timer = nil
        guard snap.phase != .idle, !snap.paused, let deadline = snap.deadline else { return }
        let t = Timer(fire: deadline.addingTimeInterval(0.05), interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated {
                CoucoudoroController.shared.timer = nil
                CoucoudoroController.shared.tick()
            }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard isPillActive else { updatePolling(); return }
        let (next, events) = CoucoudoroEngine.tick(snap, config: CoucoudoroSettings.config, now: Date())
        guard next != snap else { ensureTimer(); return }
        snap = next
        publish()
        if let last = events.last { surface(last) }
        ensureTimer()
    }

    private func publish() {
        phase = snap.phase
        paused = snap.paused
        deadline = snap.deadline
        pausedRemaining = snap.pausedRemaining
        notice = snap.notice
    }

    // MARK: - Pill

    /// The event lands on the Coucoudoro pill. The island opens onto that pill unless a card
    /// the user is in the middle of (an approval, a question, the chat) is already up.
    private func surface(_ event: CoucoudoroEvent) {
        noticeUntil = Date().addingTimeInterval(8)
        let copy = banner(at: Date()) ?? Self.text(for: event)
        // Working keeps the pill's place beside the one in front, through rest as well as work.
        let bot: BotState = (snap.phase != .idle && !snap.paused) ? .working : .idle
        paint(state: bot, steps: [copy])
        let state = AppState.shared
        if canSurface(in: state) {
            state.focusId = Self.pillId
            if let idx = state.tasks.firstIndex(where: { $0.id == Self.pillId }) {
                state.tasks[idx].pillBadge = nil
            }
            if state.mode != .expanded {
                NotificationCenter.default.post(name: .hookExpand, object: IslandView.overview)
            } else if state.view != .overview {
                state.view = .overview
            }
        } else if state.focusId != Self.pillId {
            state.setPillBadge(.finished, for: Self.pillId)
        }
        SoundEngine.shared.play(sound(for: event))
    }

    /// Don't take the island away from a card the user is busy in.
    private func canSurface(in state: AppState) -> Bool {
        if state.pendingApproval != nil || state.pendingQuestion != nil { return false }
        if state.mode != .expanded { return true }
        switch state.view {
        case .overview, .empty, .finished, .error: return true
        default: return false
        }
    }

    private func sound(for event: CoucoudoroEvent) -> String {
        switch event {
        case .workStarts: return "work"
        case .restStarts: return "finish"
        }
    }

    private func paint(state bot: BotState, steps: [String]) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == Self.pillId }) else { return }
        state.tasks[idx].state = bot
        state.tasks[idx].steps = steps
    }

    private func paintIdle() {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == Self.pillId }) else { return }
        state.tasks[idx].state = .idle
        state.tasks[idx].steps = []
        state.tasks[idx].pillBadge = nil
        if let name = PillCatalog.definition(for: Self.pillId)?.name {
            state.tasks[idx].name = name
        }
    }
}
