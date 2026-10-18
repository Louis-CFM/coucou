#if !APPSTORE
import AppKit
import Combine
import Foundation

/// Coucou adapter for system Now Playing; dedicated music controllers stay independent.
@MainActor
final class ChromeController: ObservableObject {
    static let shared = ChromeController()
    // Keep legacy identifiers stable so existing activation and connection choices survive.
    nonisolated static let pillId = "integration_chrome"
    nonisolated static let accentHex = "#C5C8CD"
    nonisolated private static let enabledKey = "coucou.chromeNowPlayingEnabled"

    @Published private(set) var track: PlaybackSnapshot?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var running = false
    @Published private(set) var connectionMessage =
        "Conecta Ahora suena para mostrar la reproducción de otras aplicaciones."
    @Published private(set) var controlsBusy = false
    @Published private(set) var commandNotice: String?
    private let client = SystemNowPlaying()
    private var subscriptions = Set<AnyCancellable>()

    var isPlaying: Bool { track?.playing == true }
    private var active: Bool { AppState.shared.activeIntegrations.contains(Self.pillId) }
    private var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    private init() {
        client.$snapshot.sink { [weak self] snapshot in self?.receive(snapshot) }.store(in: &subscriptions)
        client.$artwork.assign(to: &$artwork)
        client.$running.assign(to: &$running)
        client.$status.assign(to: &$connectionMessage)
        client.$controlsBusy.assign(to: &$controlsBusy)
        client.$commandNotice.assign(to: &$commandNotice)
        AppState.shared.$activeIntegrations.map { $0.contains(Self.pillId) }.removeDuplicates()
            .sink { [weak self] _ in
                // @Published sends before AppState has stored the new set.
                Task { @MainActor [weak self] in self?.updateConnection() }
            }.store(in: &subscriptions)
        let center = NSWorkspace.shared.notificationCenter
        center.publisher(for: NSWorkspace.willSleepNotification).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.client.stop(message: "En reposo.") }
        }.store(in: &subscriptions)
        center.publisher(for: NSWorkspace.didWakeNotification).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateConnection() }
        }.store(in: &subscriptions)
    }

    private func updateConnection() {
        if active && enabled { client.start() } else { client.stop() }
    }
    func connect() {
        guard active else { return }
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        client.start()
    }
    func disconnect() {
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        client.stop()
    }
    func shutdown() {
        client.stop()
        subscriptions.removeAll()
    }

    private func receive(_ snapshot: PlaybackSnapshot?) {
        let started = !isPlaying && snapshot?.playing == true
        track = snapshot
        let title = snapshot?.title ?? ""
        let name = title.isEmpty ? "Ahora suena" : title
        let state = AppState.shared
        if let index = state.tasks.firstIndex(where: { $0.id == Self.pillId }), state.tasks[index].name != name {
            state.tasks[index].name = name
        }
        if started && active {
            state.setFocus(Self.pillId)
            NotificationCenter.default.post(name: .musicReveal, object: nil)
        }
    }

    func position(at date: Date) -> Double { client.position(at: date) }
    func playPause() { client.playPause() }
    func previousTrack() { client.previous() }
    func nextTrack() { client.next() }
    func seek(to seconds: Double) { client.seek(seconds) }
    func openPlayer() {
        guard let track,
            let application = NSRunningApplication(processIdentifier: track.pid),
            application.bundleIdentifier == track.bundleIdentifier
        else { return }
        application.activate()
    }
}
#endif
