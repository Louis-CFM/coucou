#if !APPSTORE
import Foundation
import AppKit
import Combine

// MARK: - NowPlaying MediaRemote Adapter (from boringNotch)
// Bridges MediaRemote.framework via mediaremote-adapter.pl to capture now-playing metadata
// and artwork from Apple Music, YouTube (Safari/Chrome/Arc/Brave), Spotify, and all media players.

@MainActor
final class NowPlayingMediaRemote: ObservableObject {
    static let shared = NowPlayingMediaRemote()

    @Published var title: String?
    @Published var artist: String?
    @Published var album: String?
    @Published var artwork: NSImage?
    @Published var isPlaying: Bool = false
    @Published var bundleIdentifier: String?
    @Published var appName: String?
    @Published var duration: Double = 0
    @Published var elapsedTime: Double = 0

    private var process: Process?
    private var outputPipe: Pipe?
    private var streamTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var isRunning: Bool = false

    private init() {
        startStreaming()
        fetchCurrent()
        // Lightweight backup poll every 2.5s to ensure out-of-band changes (e.g. YouTube tab switch) are caught
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.fetchCurrent()
            }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        streamTask?.cancel()
        streamTask = nil
        if let p = process, p.isRunning {
            p.terminate()
        }
        process = nil
    }

    private func findAdapterPaths() -> (scriptPath: String, frameworkPath: String)? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser

        // 1. Persistent Application Support location (guaranteed to survive git pull and app updates)
        let appSupportScript = home.appendingPathComponent("Library/Application Support/NotchBuddy/mediaremote/mediaremote-adapter.pl").path
        let appSupportFramework = home.appendingPathComponent("Library/Application Support/NotchBuddy/mediaremote/MediaRemoteAdapter.framework").path

        if fileManager.fileExists(atPath: appSupportScript) && fileManager.fileExists(atPath: appSupportFramework) {
            return (appSupportScript, appSupportFramework)
        }

        // 2. BoringNotch installed app location
        let boringScript = "/Applications/boringNotch.app/Contents/Resources/mediaremote-adapter.pl"
        let boringFramework = "/Applications/boringNotch.app/Contents/Frameworks/MediaRemoteAdapter.framework"
        if fileManager.fileExists(atPath: boringScript) && fileManager.fileExists(atPath: boringFramework) {
            return (boringScript, boringFramework)
        }

        // 3. App bundle resources
        if let scriptURL = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl") {
            let framework = (Bundle.main.privateFrameworksPath ?? "") + "/MediaRemoteAdapter.framework"
            if fileManager.fileExists(atPath: framework) {
                return (scriptURL.path, framework)
            }
        }

        return nil
    }

    func startStreaming() {
        guard !isRunning else { return }
        guard let paths = findAdapterPaths() else { return }

        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        proc.arguments = [paths.scriptPath, paths.frameworkPath, "stream", "--no-diff"]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        self.process = proc
        self.outputPipe = pipe
        self.isRunning = true

        do {
            try proc.run()
        } catch {
            self.isRunning = false
            return
        }

        streamTask = Task.detached { [weak self, pipe] in
            let handle = pipe.fileHandleForReading
            var buffer = Data()

            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)

                while let newlineIndex = buffer.firstIndex(of: 0x0A) { // '\n'
                    let lineData = buffer.subdata(in: 0..<newlineIndex)
                    buffer.removeSubrange(0...newlineIndex)

                    if let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !line.isEmpty {
                        await self?.handleLine(line)
                    }
                }
            }
        }
    }

    func fetchCurrent() {
        guard let paths = findAdapterPaths() else { return }
        Task.detached { [weak self] in
            let p = Process()
            let pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            p.arguments = [paths.scriptPath, paths.frameworkPath, "get"]
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do {
                try p.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !str.isEmpty {
                    await self?.handleJSONString(str)
                }
            } catch {
                // Ignore error silently
            }
        }
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }

        if let payload = json["payload"] as? [String: Any] {
            parsePayload(payload)
        } else {
            parsePayload(json)
        }
    }

    private func handleJSONString(_ str: String) {
        guard let data = str.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }
        parsePayload(json)
    }

    private func parsePayload(_ payload: [String: Any]) {
        let isPlaying = (payload["playing"] as? Bool) ?? false
        let title = payload["title"] as? String
        let artist = payload["artist"] as? String
        let album = payload["album"] as? String
        let bundleID = (payload["parentApplicationBundleIdentifier"] as? String)
                    ?? (payload["bundleIdentifier"] as? String)
        let duration = (payload["duration"] as? Double) ?? 0
        let elapsed = (payload["elapsedTime"] as? Double) ?? 0

        var artworkImage: NSImage? = nil
        if let base64 = payload["artworkData"] as? String,
           !base64.isEmpty,
           let artData = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) {
            artworkImage = NSImage(data: artData)
        }

        let appDisplayName: String? = {
            guard let bid = bundleID else { return nil }
            if bid == "com.apple.Music" { return "Apple Music" }
            if bid.contains("spotify") { return "Spotify" }
            if bid.contains("Chrome") || bid.contains("Safari") || bid.contains("Browser") || bid.contains("Arc") {
                return "YouTube"
            }
            return nil
        }()

        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.title != title { self.title = title }
            if self.artist != artist { self.artist = artist }
            if self.album != album { self.album = album }
            if self.isPlaying != isPlaying { self.isPlaying = isPlaying }
            if self.bundleIdentifier != bundleID { self.bundleIdentifier = bundleID }
            if self.appName != appDisplayName { self.appName = appDisplayName }
            if self.duration != duration { self.duration = duration }
            self.elapsedTime = elapsed
            if let artworkImage {
                self.artwork = artworkImage
            }
        }
    }

    func playPause() {
        sendCommand(2)
    }

    func nextTrack() {
        sendCommand(4)
    }

    func previousTrack() {
        sendCommand(5)
    }

    private func sendCommand(_ cmd: Int) {
        guard let paths = findAdapterPaths() else { return }
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            p.arguments = [paths.scriptPath, paths.frameworkPath, "send", "\(cmd)"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
    }
}
#endif
