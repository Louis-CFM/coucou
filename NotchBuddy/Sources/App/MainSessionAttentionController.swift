import AppKit
import SwiftUI

@MainActor
final class MainSessionAttentionController {
    static let shared = MainSessionAttentionController()
    /// A dead reader is relaunched with backoff at most this many times.
    private static let maxRestartAttempts = 5
    private var queue = MainSessionAttentionQueue()
    private var process: Process?
    private var hookInput: FileHandle?
    private let hookWriter = DispatchQueue(label: "coucou.attention.hooks")
    /// Alive only while an entry is on the card — never an always-on timer.
    private var expiryTimer: Timer?
    private var stopping = false
    private var needsReveal = false
    private(set) var isEnabled = false
    /// Main (root) sessions only, or verified child/subagent sessions too.
    private var mainSessionsOnly = true
    private var restartAttempts = 0
    /// Bumped on every launch; a termination callback only counts when its
    /// generation is still current, so a late old readerDied can never clear
    /// a newer process' state.
    private var generation = 0
    /// A pending backoff relaunch; cancelled on stop and scope changes.
    private var restartTask: Task<Void, Never>?
    /// Isolated smoke test flag: synthetic snapshots are accepted while the
    /// feature stays off and no reader process or timer is ever started.
    private var smokeSnapshots = false

    /// Snapshots update the card only while the feature is on (or the isolated
    /// DEBUG smoke test is running); a stale or foreign reader is ignored.
    var acceptsSnapshots: Bool {
        MainSessionAttentionPolicy.acceptsSnapshots(featureEnabled: isEnabled, smokeSynthetic: smokeSnapshots)
    }

    // MARK: - Opt-in lifecycle (GitHub build only)

    func setEnabled(_ enabled: Bool) {
        #if !APPSTORE
        if enabled { start() } else { stop() }
        #endif
    }

    /// Main (root) sessions only, or verified child sessions too. The reader is
    /// restarted only when the feature is on and the scope actually changed.
    func setMainSessionsOnly(_ only: Bool) {
        #if !APPSTORE
        let changed = mainSessionsOnly != only
        mainSessionsOnly = only
        guard isEnabled, changed else { return }
        cancelRestartTask()
        teardownReader()
        queue = MainSessionAttentionQueue()
        publish(reveal: false)
        restartAttempts = 0
        launchReader()
        #endif
    }

    func start() {
        #if !APPSTORE
        guard !isEnabled else { return }
        // AppState's init does not fire didSet: sync the persisted scope here
        // so the first reader launch uses the saved session scope.
        mainSessionsOnly = AppState.shared.mainSessionAttentionOnly
        isEnabled = true
        MainSessionAttentionRoute.setEnabled(true)
        stopping = false
        restartAttempts = 0
        launchReader()
        #endif
    }

    /// Clears the pending list, stops the expiry timer and closes the hook pipe
    /// and the reader process. Safe to call repeatedly.
    func stop() {
        isEnabled = false
        MainSessionAttentionRoute.setEnabled(false)
        stopping = true
        cancelRestartTask()
        expiryTimer?.invalidate()
        expiryTimer = nil
        teardownReader()
        queue = MainSessionAttentionQueue()
        publish(reveal: false)
    }

    #if DEBUG
    /// Isolated headless smoke test: accept synthetic snapshots without turning
    /// the feature on, launching a reader or scheduling any timer.
    func enableSmokeSnapshots() {
        smokeSnapshots = true
        MainSessionAttentionRoute.setEnabled(true)
    }
    #endif

    // MARK: - Reader process

    private func launchReader() {
        #if !APPSTORE
        guard isEnabled, !stopping, process == nil, restartAttempts <= Self.maxRestartAttempts,
              let script = Bundle.main.url(forResource: "attention_bridge", withExtension: "py") else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        var arguments = [script.path, "--socket", HookServer.socketPath, "--hooks-stdin"]
        if !mainSessionsOnly { arguments.append("--include-child-sessions") }
        task.arguments = arguments
        let input = Pipe()
        task.standardInput = input
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        generation += 1
        let born = generation
        task.terminationHandler = { _ in
            Task { @MainActor in Self.shared.readerDied(generation: born) }
        }
        do {
            try task.run()
            process = task
            hookInput = input.fileHandleForWriting
        } catch {
            process = nil
            hookInput = nil
            scheduleRestart()
        }
        #endif
    }

    /// Unexpected reader death: nothing it verified is still guaranteed, so the
    /// pending list is dropped and a bounded backoff restart is scheduled. Only
    /// the current generation counts — a late callback from an earlier reader
    /// must never clear a newer process' state.
    private func readerDied(generation born: Int) {
        guard isEnabled, !stopping, process != nil, generation == born else { return }
        hookInput = nil
        process = nil
        queue = MainSessionAttentionQueue()
        publish(reveal: false)
        scheduleRestart()
    }

    /// Bounded retries with exponential backoff; once the budget is spent the
    /// reader stays down until the feature is toggled again.
    private func scheduleRestart() {
        guard isEnabled, !stopping else { return }
        cancelRestartTask()
        restartAttempts += 1
        guard restartAttempts <= Self.maxRestartAttempts else {
            teardownReader()
            queue = MainSessionAttentionQueue()
            publish(reveal: false)
            return
        }
        let delay = min(60.0, 5.0 * pow(2.0, Double(restartAttempts - 1)))
        restartTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, Self.shared.isEnabled, !Self.shared.stopping else { return }
            Self.shared.launchReader()
        }
    }

    private func cancelRestartTask() {
        restartTask?.cancel()
        restartTask = nil
    }

    /// Closes the hook pipe and terminates the reader process; its termination
    /// handler is detached first so a deliberate stop is not mistaken for a crash.
    private func teardownReader() {
        process?.terminationHandler = nil
        try? hookInput?.close()
        hookInput = nil
        process?.terminate()
        process = nil
    }

    // MARK: - Snapshots and hook hints

    func receive(_ payload: [String: Any]) {
        // Defense in depth beyond the HookServer gate: a disabled feature
        // ignores every snapshot, wherever it came from.
        guard acceptsSnapshots else { return }
        let isNew = queue.replace(payload: payload, now: Date().timeIntervalSince1970)
        // A snapshot proves the reader is alive and talking: reset the backoff budget.
        restartAttempts = 0
        publish(reveal: isNew)
    }

    func receiveHook(_ payload: [String: Any]) {
        #if !APPSTORE
        guard isEnabled, let input = hookInput,
              var data = try? JSONSerialization.data(withJSONObject: payload), data.count <= 65_536 else { return }
        data.append(10)
        let line = data
        // Pipe I/O must never hold the notch's main thread or an approval request open.
        hookWriter.async { try? input.write(contentsOf: line) }
        #endif
    }

    func dismiss(_ request: MainSessionAttention) {
        queue.dismiss(id: request.id)
        publish(reveal: false)
    }

    func open(_ request: MainSessionAttention) {
        // OpenCode 2.0.30 has no session navigation handler; show the chat title on the card.
        // Never fabricate an OpenCode deep link or send a permission response.
        if let url = request.chatURL {
            if NSWorkspace.shared.open(url) { dismiss(request) }
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: request.bundleId) {
            NSWorkspace.shared.openApplication(at: app, configuration: .init()) { app, _ in
                guard app != nil else { return }
                Task { @MainActor in Self.shared.dismiss(request) }
            }
        }
    }

    private func publish(reveal: Bool) {
        needsReveal = needsReveal || reveal
        let state = AppState.shared
        var display = queue.visible
        // Lease refreshes are bookkeeping; they must not redraw every mounted island view.
        for index in display.indices { display[index].expiresAt = 0 }
        if state.pendingAttention != display { state.pendingAttention = display }
        if queue.visible.isEmpty {
            needsReveal = false
            expiryTimer?.invalidate()
            expiryTimer = nil
            if state.view == .attention {
                state.view = state.pendingApproval != nil ? .approval : (state.pendingQuestion != nil ? .question : .overview)
                if state.pendingApproval == nil && state.pendingQuestion == nil {
                    NotificationCenter.default.post(name: .islandCollapse, object: nil)
                }
            }
        } else {
            scheduleExpiryTimer()
            if needsReveal && state.pendingApproval == nil && state.pendingQuestion == nil {
                needsReveal = false
                SoundEngine.shared.play("question")
                NotificationCenter.default.post(name: .hookExpand, object: IslandView.attention)
            }
        }
    }

    /// Leases are re-checked only while something is actually on the card — and
    /// never in the isolated smoke test, which runs no timers at all.
    private func scheduleExpiryTimer() {
        #if DEBUG
        guard !smokeSnapshots else { return }
        #endif
        guard expiryTimer == nil else { return }
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in
                let controller = Self.shared
                controller.queue.expire(now: Date().timeIntervalSince1970)
                controller.publish(reveal: false)
            }
        }
    }
}

struct MainSessionAttentionView: View {
    @ObservedObject var state: AppState

    var body: some View {
        if let request = state.pendingAttention.first {
            MainSessionAttentionCard(request: request, count: state.pendingAttention.count,
                                     onOpen: { MainSessionAttentionController.shared.open(request) },
                                     onDismiss: { MainSessionAttentionController.shared.dismiss(request) })
        }
    }
}
