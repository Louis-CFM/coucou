#if !APPSTORE
import Foundation
import AppKit
import Combine

// MARK: - Yandex Music Controller

/// The track Yandex Music has loaded, as macOS Now Playing describes it.
struct YandexMusicTrack: Equatable, Sendable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let duration: Double    // seconds, 0 = unknown
}

/// Observes Yandex Music through the system's Now Playing and drives it with media commands.
/// Singleton, @MainActor, GitHub build only (the App Store sandbox would block `osascript`).
/// Since macOS 15.4 only Apple's own processes may read Now Playing, so a small `osascript` watcher does
/// it for us. It runs only while the pill is active and Yandex Music is open; nothing else polls.
@MainActor
final class YandexMusicController: ObservableObject {
    static let shared = YandexMusicController()
    nonisolated static let pillId = "integration_yandex_music"
    nonisolated static let yellow = "#FFEE00"

    @Published private(set) var track: YandexMusicTrack?
    @Published private(set) var isPlaying = false
    /// Position (seconds) at `positionDate`; while playing, the real position runs on from there.
    @Published private(set) var positionAnchor: Double = 0
    @Published private(set) var positionDate = Date()
    /// Now Playing carries no cover we can read, so this stays nil.
    @Published private(set) var artwork: NSImage?
    /// The watcher can't read Now Playing on this Mac (or keeps crashing).
    @Published private(set) var nowPlayingUnavailable = false

    private var notifTokens: [Any] = []
    private var cancellables = Set<AnyCancellable>()
    private let queue = DispatchQueue(label: "fr.louisraille.coucou.yandexmusic")

    private var watcher: Process?
    private var watcherGeneration = 0
    private var restartTask: Task<Void, Never>?
    private var failures: [Date] = []

    private var isPillActive: Bool {
        AppState.shared.activeIntegrations.contains(Self.pillId)
    }

    var isInstalled: Bool {
        YandexMusicNowPlaying.bundleIds.contains {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
    }

    var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            !$0.isTerminated && YandexMusicNowPlaying.bundleIds.contains($0.bundleIdentifier ?? "")
        }
    }

    /// Where playback is now, extrapolated from the last anchor.
    func position(at date: Date) -> Double {
        let elapsed = isPlaying ? date.timeIntervalSince(positionDate) : 0
        let p = positionAnchor + max(0, elapsed)
        guard let d = track?.duration, d > 0 else { return p }
        return min(p, d)
    }

    private init() {
        // Yandex Music launched or quit: start or stop the watcher
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let tok = NSWorkspace.shared.notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notif in
                let bundleId = (notif.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication)?.bundleIdentifier
                guard let bundleId, YandexMusicNowPlaying.bundleIds.contains(bundleId) else { return }
                Task { @MainActor [weak self] in self?.syncWatcher() }
            }
            notifTokens.append(tok)
        }

        // Coucou quitting: don't leave the watcher behind
        let tok = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.stopWatcher() }
        }
        notifTokens.append(tok)

        // Pill turned on or off
        AppState.shared.$activeIntegrations
            .sink { [weak self] _ in
                // The publisher fires before the property is set: read once it is
                Task { @MainActor [weak self] in self?.syncWatcher() }
            }
            .store(in: &cancellables)

        syncWatcher()
    }

    // MARK: - State

    private func handle(_ line: YandexMusicHelperLine) {
        switch line {
        case .ready(let available):
            if available {
                nowPlayingUnavailable = false
            } else {
                // This Mac won't give us Now Playing: no point restarting
                nowPlayingUnavailable = true
                stopWatcher()
                clearState()
                appendAppLog("nb.log", "[YandexMusic] Now Playing unavailable on this Mac")
            }
        case .nothing:
            clearState()
        case .snapshot(let s):
            guard isPillActive, YandexMusicNowPlaying.isYandex(s) else { clearState(); return }
            setTrack(YandexMusicTrack(
                id: YandexMusicNowPlaying.trackId(s),
                title: YandexMusicNowPlaying.shortTitle(s.title),
                artist: YandexMusicNowPlaying.shortArtist(s.artist),
                album: s.album,
                duration: s.duration
            ))
            // Play state first: its transition re-anchors, and the snapshot's position wins
            setPlaying(s.playing || s.rate > 0)
            positionAnchor = max(0, s.elapsed)
            positionDate = s.timestamp > 0 ? Date(timeIntervalSince1970: s.timestamp) : Date()
        }
    }

    private func setTrack(_ newTrack: YandexMusicTrack) {
        guard track != newTrack else { return }
        track = newTrack
        syncTaskName()
    }

    private func setPlaying(_ playing: Bool) {
        let wasPlaying = isPlaying
        if playing != wasPlaying {
            // Freeze or restart the clock at the current position
            anchor(position(at: Date()))
        }
        isPlaying = playing
        // Reveal only on transition from not-playing → playing
        if playing && !wasPlaying {
            NotificationCenter.default.post(name: .musicReveal, object: nil)
        }
    }

    private func anchor(_ position: Double) {
        positionAnchor = max(0, position)
        positionDate = Date()
    }

    private func clearState() {
        track = nil
        artwork = nil
        isPlaying = false
        anchor(0)
        syncTaskName()
    }

    private func syncTaskName() {
        guard let idx = AppState.shared.tasks.firstIndex(where: { $0.id == Self.pillId }) else { return }
        let title = track?.title ?? ""
        AppState.shared.tasks[idx].name = title.isEmpty
            ? (PillCatalog.definition(for: Self.pillId)?.name ?? "Yandex Music")
            : title
    }

    // MARK: - Watcher

    /// Runs the watcher only while the pill is active and Yandex Music is open.
    private func syncWatcher() {
        guard isPillActive, isRunning else {
            restartTask?.cancel()
            restartTask = nil
            failures.removeAll()
            nowPlayingUnavailable = false
            stopWatcher()
            clearState()
            return
        }
        guard watcher == nil, !nowPlayingUnavailable, restartTask == nil else { return }
        startWatcher()
    }

    private func startWatcher() {
        watcherGeneration += 1
        let generation = watcherGeneration

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", YandexMusicNowPlaying.watchScript]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let buffer = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            // Parse here, off the main actor: the parsed lines are Sendable
            for text in buffer.append(data) {
                guard let line = YandexMusicNowPlaying.parse(line: text) else { continue }
                Task { @MainActor [weak self] in
                    guard let self, self.watcherGeneration == generation else { return }
                    self.handle(line)
                }
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.watcherEnded(generation: generation) }
        }

        do {
            try process.run()
            watcher = process
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            appendAppLog("nb.log", "[YandexMusic] watcher failed to start: \(error.localizedDescription)")
            watcherFailed()
        }
    }

    private func stopWatcher() {
        watcherGeneration += 1   // lines and termination of the old process no longer count
        guard let process = watcher else { return }
        watcher = nil
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    private func watcherEnded(generation: Int) {
        guard generation == watcherGeneration else { return }   // stopped on purpose
        (watcher?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        watcher = nil
        watcherFailed()
    }

    /// Restarts after 1 s, 5 s, then 30 s; gives up after 3 failures within 2 minutes.
    private func watcherFailed() {
        let now = Date()
        failures = failures.filter { now.timeIntervalSince($0) < 120 } + [now]
        guard isPillActive, isRunning else { return }
        if failures.count >= 3 {
            nowPlayingUnavailable = true
            appendAppLog("nb.log", "[YandexMusic] watcher keeps failing, giving up")
            return
        }
        let delay: [Double] = [1, 5, 30]
        let seconds = delay[min(failures.count - 1, delay.count - 1)]
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.restartTask = nil
            self?.syncWatcher()
        }
    }

    /// Collects the watcher's output and hands back whole lines. Used from the pipe's queue.
    private final class LineBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = Data()

        func append(_ data: Data) -> [String] {
            lock.lock(); defer { lock.unlock() }
            pending.append(data)
            var lines: [String] = []
            while let newline = pending.firstIndex(of: 0x0A) {
                let chunk = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                if let text = String(data: chunk, encoding: .utf8), !text.isEmpty { lines.append(text) }
            }
            return lines
        }
    }

    // MARK: - Reading Yandex Music

    /// Reads Now Playing once (when the card appears, or after a command). Never launches Yandex Music.
    func refresh() {
        guard isPillActive, isRunning else { return }
        Task {
            let output = await Self.runOsascript(
                ["-l", "JavaScript", "-e", YandexMusicNowPlaying.watchScript, "once"], on: queue)
            // The last line is the current state ("ready" is only printed by the long-running watcher)
            guard let text = output.split(separator: "\n").last,
                  let line = YandexMusicNowPlaying.parse(line: String(text)),
                  isPillActive else { return }
            handle(line)
        }
    }

    // MARK: - Playback controls

    func playPause() {
        guard isRunning else { return }
        setPlaying(!isPlaying)   // optimistic; the next read confirms
        command("toggle", onOther: { [weak self] in
            // Yandex Music isn't what macOS is playing: undo, and bring the app up
            guard let self else { return }
            self.setPlaying(!self.isPlaying)
            self.openYandexMusic()
        })
    }

    func play() {
        guard isRunning else { return }
        command("play")
    }

    func pause() {
        guard isRunning else { return }
        command("pause")
    }

    func nextTrack() {
        guard isRunning else { return }
        command("next")
    }

    func previousTrack() {
        guard isRunning else { return }
        command("previous")
    }

    func seek(to seconds: Double) {
        guard isRunning, let track else { return }
        let target = min(max(0, seconds), max(0, track.duration - 1))
        anchor(target)   // optimistic
        command("seek", value: String(target))
    }

    /// Sends a media command to Yandex Music only (the script refuses when another app owns Now Playing).
    private func command(_ verb: String, value: String = "", onOther: (@MainActor () -> Void)? = nil) {
        Task {
            let args = ["-l", "JavaScript", "-e", YandexMusicNowPlaying.commandScript, verb, value]
                + YandexMusicNowPlaying.bundleIds
            let result = await Self.runOsascript(args, on: queue)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            switch result {
            case "ok":
                // Let Yandex Music settle on the new track before reading it back
                try? await Task.sleep(for: .milliseconds(350))
                refresh()
            case "other":
                onOther?()
            default:
                appendAppLog("nb.log", "[YandexMusic] \(verb) failed: \(result.isEmpty ? "no answer" : result)")
            }
        }
    }

    func openYandexMusic() {
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            YandexMusicNowPlaying.bundleIds.contains($0.bundleIdentifier ?? "")
        }) {
            app.activate()
        } else if let url = YandexMusicNowPlaying.bundleIds.lazy
            .compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first {
            NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
        }
    }

    func openDownloadPage() {
        NSWorkspace.shared.open(URL(string: "https://music.yandex.ru/download/")!)
    }

    // MARK: - osascript runner

    /// Runs `osascript` to the end (killed after 5 s) and returns what it printed.
    nonisolated private static func runOsascript(_ arguments: [String], on queue: DispatchQueue) async -> String {
        await withCheckedContinuation { cont in
            queue.async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch {
                    cont.resume(returning: ""); return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    if process.isRunning { process.terminate() }
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
        }
    }
}
#endif
