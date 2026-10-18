// The return to idle each pill's Stop arms, kept so the next turn can cancel
// it. Without that, a prompt sent within 5.2 s of Stop was flipped back to
// idle (or an agent's pill removed) in the middle of its new turn.
@MainActor
final class StopTimerBook {
    private var timers: [String: Task<Void, Never>] = [:]

    nonisolated init() {}

    func arm(_ pill: String, after seconds: Double, _ work: @escaping @MainActor () -> Void) {
        timers[pill]?.cancel()
        timers[pill] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.timers[pill] = nil
            work()
        }
    }

    @discardableResult
    func cancel(_ pill: String) -> Bool {
        guard let timer = timers.removeValue(forKey: pill) else { return false }
        timer.cancel()
        return true
    }

    func isArmed(_ pill: String) -> Bool {
        timers[pill] != nil
    }
}
