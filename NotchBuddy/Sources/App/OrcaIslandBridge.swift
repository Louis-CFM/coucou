import AppKit
import Combine
import Observation

/// Feeds the island with Orca data: owns the `OrcaStore`, mirrors its snapshot into `AppState`, and
/// tells the store what the app is doing so it can pick the poll rate (OrcaPollPolicy):
/// fast while the island is on screen, slow while it is hidden or the Mac / screen sleeps.
@MainActor
final class OrcaIslandBridge {
    static let shared = OrcaIslandBridge()

    let store = OrcaStore()
    private var cancellables = Set<AnyCancellable>()
    private var asleep = false
    private var started = false
    private var keepsVisible = false

    func start() {
        guard !started else { return }
        started = true
        let state = AppState.shared

        // Island visibility drives the poll rate.
        state.$mode
            .map { $0 != .hidden }
            .removeDuplicates()
            .sink { [weak self] _ in self?.applyActivity() }
            .store(in: &cancellables)

        // Sleep / wake of the Mac and of the screens.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            ws.publisher(for: name).sink { [weak self] _ in self?.asleep = true; self?.applyActivity() }
                .store(in: &cancellables)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            ws.publisher(for: name).sink { [weak self] _ in self?.asleep = false; self?.applyActivity() }
                .store(in: &cancellables)
        }

        applyActivity()
        store.start()
        track()
    }

    private func applyActivity() {
        store.setActivity(islandVisible: AppState.shared.mode != .hidden, asleep: asleep)
    }

    /// Re-armed observation of the store's snapshot (Observation fires once per change).
    private func track() {
        withObservationTracking {
            _ = store.snapshot
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.publish()
                self?.track()
            }
        }
    }

    private func publish() {
        let state = AppState.shared
        let snapshot = store.snapshot
        state.setIfChanged(\.orca, snapshot)
        let visible = snapshot.agentCounts.keepsIslandVisible
        guard visible != keepsVisible else { return }
        keepsVisible = visible
        let fsm = (NSApp.delegate as? AppDelegate)?.islandController?.fsm
        if visible { fsm?.reveal() } else { fsm?.resumeHideTimer() }
        state.syncMode()
    }
}
