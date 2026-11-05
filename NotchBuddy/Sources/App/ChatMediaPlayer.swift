import Foundation
import AVFoundation

// Plays one verified audio file of a chat row: a voice note or a sound the agent made.
//
// `AVAudioFile` and an engine, not `AVAudioPlayer`: on macOS 26 `AVAudioPlayer` opens an Ogg Opus file and reports its
// duration, but `prepareToPlay()` and `play()` return false, while `AVAudioFile` reads it and plays it (WAVE, MP3, M4A
// and FLAC play either way). Hermes voice notes are Ogg Opus, so this is the path that matters.
//
// No timer, no running engine while paused or finished: pausing reads the position, takes the engine down, and playing
// builds it again from that position. 0 % CPU when nothing plays. Foundation and AVFoundation only, no flag.

/// What the store needs from a player, so a test can stand a fake in its place.
@MainActor
protocol ChatMediaPlaying: AnyObject {
    var isPlaying: Bool { get }
    var currentTime: Double { get }
    var onFinish: (() -> Void)? { get set }
    var onInterrupted: (() -> Void)? { get set }
    @discardableResult func play() -> Bool
    func pause()
    func stop()
}

@MainActor
final class ChatMediaPlayer: ChatMediaPlaying {
    /// The longest file the app plays: a chat voice note or sound is far shorter, and anything longer is a document the
    /// person can save.
    nonisolated static let maxSeconds: Double = 2 * 3600

    private let file: AVAudioFile
    private let rate: Double
    private let length: AVAudioFramePosition
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    /// The frame where the current or next play starts.
    private var startFrame: AVAudioFramePosition = 0
    /// The last position read while playing: what a pause keeps when the engine cannot say where it is.
    private var lastKnownFrame: AVAudioFramePosition = 0
    private var generation = 0
    private var observer: NSObjectProtocol?

    private(set) var isPlaying = false
    /// 1 in the app. The tests play at 0.
    var volume: Float = 1
    /// The sound reached its end by itself.
    var onFinish: (() -> Void)?
    /// The output went away (a device change): the sound stopped, the position stays.
    var onInterrupted: (() -> Void)?

    let duration: Double

    /// What an ordinary recording is: one to eight channels, 8 000 to 192 000 Hz. The engine reports a format it dislikes
    /// as an Objective-C exception (a WAVE of 1 025 channels ended the process), so anything outside is a document.
    nonisolated static let channelRange = 1...8
    nonisolated static let rateRange: ClosedRange<Double> = 8_000...192_000

    /// Whether a file of that many frames at that rate may be played: not empty, within what the engine counts
    /// (`AVAudioFrameCount`, 32 bits), and no longer than `maxSeconds`. Pure.
    nonisolated static func isPlayable(frames: Int64, rate: Double) -> Bool {
        guard frames > 0, rate > 0, rate.isFinite, frames <= Int64(AVAudioFrameCount.max) else { return false }
        return Double(frames) / rate <= maxSeconds
    }

    /// Whether the format of a file is an ordinary one: channels and rate in range, standard PCM. Pure.
    nonisolated static func isOrdinary(channels: UInt32, rate: Double, standardPCM: Bool) -> Bool {
        standardPCM && channelRange.contains(Int(channels)) && rate.isFinite && rateRange.contains(rate)
    }

    /// Opens a file and checks it is audio of an ordinary format and a sane size. Nothing is played. Safe off the main actor.
    nonisolated private static func inspect(_ url: URL) -> (file: AVAudioFile, rate: Double, seconds: Double)? {
        var opened: AVAudioFile?
        // Opening reads the header with the system's own code; an exception there is a file that does not open.
        guard CoucouTry({ opened = try? AVAudioFile(forReading: url) }), let file = opened else { return nil }
        let format = file.processingFormat
        let rate = format.sampleRate
        guard isOrdinary(channels: format.channelCount, rate: rate, standardPCM: format.isStandard),
              isPlayable(frames: file.length, rate: rate) else { return nil }
        return (file, rate, Double(file.length) / rate)
    }

    /// Nil when the file cannot be read as audio of a sane length. A file that opens here is a file that plays.
    init?(url: URL) {
        guard let opened = Self.inspect(url) else { return nil }
        self.file = opened.file
        self.rate = opened.rate
        self.length = opened.file.length
        self.duration = opened.seconds
    }

    /// The duration of a file, or nil when it is not audio this player can play. Safe off the main actor: the store
    /// checks the bytes of a fetched file there.
    nonisolated static func probe(_ url: URL) -> Double? { inspect(url)?.seconds }

    /// Seconds from the start: live while playing, the stopped position otherwise.
    var currentTime: Double {
        guard isPlaying else { return Double(startFrame) / rate }
        let frame = liveFrame() ?? lastKnownFrame
        lastKnownFrame = frame
        return min(duration, max(0, Double(frame) / rate))
    }

    /// Where the sound is now, or nil when the engine cannot say (no render time after a configuration change).
    private func liveFrame() -> AVAudioFramePosition? {
        guard isPlaying, let node, let last = node.lastRenderTime, let time = node.playerTime(forNodeTime: last) else { return nil }
        return min(length, max(0, startFrame + time.sampleTime))
    }

    @discardableResult
    func play() -> Bool {
        guard !isPlaying else { return true }
        if startFrame >= length { startFrame = 0 }
        // A checked conversion: `inspect` kept the length inside 32 bits, and this never traps whatever the position.
        guard let frames = AVAudioFrameCount(exactly: length - startFrame), frames > 0 else { return false }
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        generation += 1
        let mine = generation
        let file = self.file, start = startFrame, level = volume
        // The engine reports a problem as an Objective-C exception, which Swift cannot catch: every call that can raise
        // one goes through `CoucouTry`, and a caught one is a sound that would not start.
        var started = false
        let ran = CoucouTry {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
            engine.mainMixerNode.outputVolume = level
            node.scheduleSegment(file, startingFrame: start, frameCount: frames, at: nil,
                                 completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in self?.reachedEnd(generation: mine) }
            }
            do { try engine.start(); node.play(); started = true } catch {}
        }
        guard ran, started else {
            generation += 1
            _ = CoucouTry { node.stop(); engine.stop() }
            return false
        }
        lastKnownFrame = startFrame
        self.engine = engine
        self.node = node
        isPlaying = true
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                self.pause()
                self.onInterrupted?()
            }
        }
        return true
    }

    /// Stops the sound and keeps the position. The engine is gone: nothing runs.
    func pause() {
        guard isPlaying else { return }
        startFrame = min(length, max(0, liveFrame() ?? lastKnownFrame))
        teardown()
    }

    /// Stops and forgets the position.
    func stop() {
        startFrame = 0
        teardown()
    }

    private func teardown() {
        generation += 1
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        let node = self.node, engine = self.engine
        _ = CoucouTry { node?.stop(); engine?.stop() }
        self.node = nil
        self.engine = nil
        isPlaying = false
    }

    private func reachedEnd(generation: Int) {
        guard generation == self.generation, isPlaying else { return }
        startFrame = 0
        teardown()
        onFinish?()
    }
}
