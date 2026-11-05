import SwiftUI
import AppKit
import AVFoundation
import ImageIO

// The state of the attachment rows of the chat: what was fetched, what plays, what was saved. In memory for the app
// session only: the bytes are in a private temporary folder (`ChatMediaFiles`) and go away with the conversation or at
// quit. Nothing is logged: no path, no name, no byte.
//
// Fetching happens only for a sign in agent (`ChatMediaFetch`), only while the chat is on screen, and only up to the
// caps of `ChatMediaFetch`: two at a time, 30 MB per conversation, then a click. A click may go further (documents,
// video, bigger files). A file is never opened, run or previewed by itself: playback and "Open" are clicks, "Save…" is a
// click and a save panel. The bytes are checked (type sniff, audio probe, image decode) off the main actor.

// MARK: - Context of a conversation

/// What a row needs to know about where its answer came from. Set once per chat surface (and per turn) in the environment.
struct ChatMediaContext: Equatable {
    /// The answers of this surface come from a Hermes agent: its directives are read. Elsewhere they stay text.
    var enabled = false
    /// An opaque key of the conversation (the folder of its files; never on disk by name).
    var conversation = ""
    /// The agent, when it signs in: only then can a file be fetched. `nil` is an API key agent: nothing is requested.
    var agent: HermesAgent? = nil
    /// The name the person reads for the agent.
    var agentName = ""
    /// The colour of the agent: the position bar and the voice glyph.
    var colorHex = "#F97316"
    /// The text this row belongs to (message and segment), so two texts of a conversation never share a row state.
    var scope = ""

    var canFetch: Bool { agent?.connection == .signIn }
}

private struct ChatMediaContextKey: EnvironmentKey {
    static let defaultValue = ChatMediaContext()
}

extension EnvironmentValues {
    var chatMedia: ChatMediaContext {
        get { self[ChatMediaContextKey.self] }
        set { self[ChatMediaContextKey.self] = newValue }
    }
}

extension ConversationID {
    /// The key of this conversation for the media folders. Never written to disk.
    var mediaKey: String {
        switch self {
        case .shared: return "shared"
        case .hermes(let name): return "hermes:" + name
        }
    }
}

// MARK: - The words of the rows

/// The sentences a row says about a state. One sentence per state, one localized string each (never two joined), and no
/// size when it is not known.
enum ChatMediaWords {
    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// A file that stayed on the machine of an API key agent.
    static func unavailable(agentName: String) -> String {
        agentName.isEmpty ? String(localized: "This file is on the agent's computer. This connection cannot reach it.")
            : String(localized: "This file is on \(agentName)'s computer. This connection cannot reach it.")
    }

    /// "Fetching · 62 %", or "Fetching…" while the size is not known.
    static func fetching(fraction: Double?) -> String {
        guard let fraction else { return String(localized: "Fetching…") }
        return String(localized: "Fetching · \(Int(min(1, max(0, fraction)) * 100)) %")
    }

    /// The conversation already fetched a lot by itself: not a size problem, so not a size sentence.
    static func overBudget() -> String { String(localized: "Waiting for a click: this conversation already fetched a lot.") }

    /// The save did not happen (the disk refused, or the copy could not be marked as downloaded).
    static func saveFailed() -> String { String(localized: "Could not save the file.") }

    /// With a size that is known: "48 MB · too large to fetch by itself". Without: no size at all.
    static func tooLarge(bytes: Int?) -> String {
        guard let bytes else { return String(localized: "Too large to fetch by itself.") }
        return String(localized: "\(size(bytes)) · too large to fetch by itself")
    }
}

// MARK: - One attachment

@MainActor
final class ChatMediaItemModel: ObservableObject {
    struct Key: Hashable {
        let conversation: String
        let scope: String
        let id: Int
        let path: String
    }

    struct Ready: Equatable {
        let url: URL
        /// The kind the bytes allow (`ChatMediaSniff`), possibly demoted to a document.
        let kind: ChatAttachmentKind
        let format: ChatMediaSniff.Format
        let bytes: Int
        let duration: Double?
        let pixels: CGSize?
        /// What a file with no signature is as text: decides whether a plain data extension may be kept on save.
        var text: ChatMediaSniff.PlainText = .binary
    }

    enum Phase: Equatable {
        case fetching(received: Int, total: Int?)
        case ready(Ready)
        /// Over the automatic cap, within the manual one: waits for a click.
        case needsClick(bytes: Int?)
        /// The conversation spent its automatic budget: not about this file's size, it waits for a click too.
        case overBudget
        case failed(ChatMediaFetch.Failure)
    }

    let key: Key
    /// What the answer says about this file now: the kind and the name can change while the text streams (a tag that
    /// comes after the path). Updated by the store; the row reads it.
    var attachment: ChatAttachment
    /// nil: nothing was asked yet. Set by the store; previews and tests set it directly.
    @Published var phase: Phase?
    @Published var playing = false
    /// The copy the person saved, for "Show in Finder".
    @Published var saved: URL?
    /// The last save did not happen.
    @Published var saveFailed = false
    var thumbnail: NSImage?
    /// Where the playback stopped (seconds), for a row that is paused or finished.
    var pausedAt: Double = 0
    var task: Task<Void, Never>?
    /// How many views show this row right now. SwiftUI may build the new view of a row (its place in the card moved
    /// while the text streamed) before it drops the old one: a fetch ends only when none is left.
    fileprivate var shownBy = 0
    fileprivate var saveWhenReady = false
    /// Which fetch is in flight: a progress tick of an earlier one (cancelled, then asked again) is not for this one.
    fileprivate var fetchID = 0
    /// The fetch in flight (or queued) was started by the row itself, not by a click: it ends when the chat leaves.
    fileprivate var automatic = false
    /// The file of a row whose sound would not start, so "Try again" can play it again.
    fileprivate var playable: Ready?

    init(key: Key, attachment: ChatAttachment) {
        self.key = key
        self.attachment = attachment
    }

    /// The position now, in seconds. Reads the player only while this row plays.
    func position() -> Double {
        ChatMediaStore.shared.position(of: self)
    }
}

// MARK: - The store

@MainActor
final class ChatMediaStore {
    // `ChatMediaStore.shared` is made next to `HermesSessions.shared` (AppState.swift): the store itself knows no global.

    /// Fetches the rows start by themselves: this many at a time.
    static let maxConcurrentAutomatic = 2
    /// ...and this many bytes per conversation. A fetch starts by itself only while the bytes spent so far, plus the cap
    /// it could take (5 MB for a picture, 10 MB for a sound: reserved until the real size is known), fit in it, so the
    /// last files that start sit up to one cap below the number. The bytes that arrived count whatever the outcome (done,
    /// cut for size, failed, cancelled). Past it a row says so and waits for a click.
    static let automaticBudget = 30 << 20

    typealias Download = @Sendable (HermesAgent, String, Int, ChatMediaFiles, String, @escaping @Sendable (Int, Int?) -> Void) async -> Result<ChatMediaFetch.Downloaded, ChatMediaFetch.Failure>

    private var models: [ChatMediaItemModel.Key: ChatMediaItemModel] = [:]
    private let files: ChatMediaFiles
    private let download: Download
    private let makePlayer: @MainActor (URL) -> (any ChatMediaPlaying)?
    private let chatShown: @MainActor () -> Bool
    private let savePanel: @MainActor (String) -> URL?
    private let maxConcurrent: Int
    private let budget: Int

    private var player: (any ChatMediaPlaying)?
    private weak var active: ChatMediaItemModel?

    /// Automatic fetches waiting for a place, in order; how many run; the bytes spent or reserved per conversation.
    private struct Job {
        let model: ChatMediaItemModel
        let agent: HermesAgent
        let path: String
        let cap: Int
        let conversation: String
        let automatic: Bool
        let id: Int
        /// The bytes that reached the app for this job, noted by the download as they come.
        let received: ReceivedBytes
    }

    /// A count the download writes from its own thread and the store reads when it ends.
    final class ReceivedBytes: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func note(_ bytes: Int) { lock.lock(); count = max(count, bytes); lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
    private var nextFetchID = 0
    private var queue: [Job] = []
    private var running = 0
    private var spent: [String: Int] = [:]

    init(sessions: HermesSessions, files: ChatMediaFiles = .shared, maxConcurrent: Int? = nil, automaticBudget: Int? = nil,
         makePlayer: (@MainActor (URL) -> (any ChatMediaPlaying)?)? = nil, download: Download? = nil,
         chatShown: (@MainActor () -> Bool)? = nil, savePanel: (@MainActor (String) -> URL?)? = nil) {
        self.files = files
        self.chatShown = chatShown ?? { ChatMediaVisibility.shared.shown }
        self.savePanel = savePanel ?? { ChatMediaStore.runSavePanel(suggestedName: $0) }
        self.maxConcurrent = max(1, maxConcurrent ?? Self.maxConcurrentAutomatic)
        self.budget = automaticBudget ?? Self.automaticBudget
        self.makePlayer = makePlayer ?? { ChatMediaPlayer(url: $0) }
        self.download = download ?? { agent, path, cap, files, conversation, progress in
            await ChatMediaFetch.download(agent: agent, path: path, cap: cap, sessions: sessions, files: files,
                                          conversation: conversation, progress: progress)
        }
    }

    func model(for attachment: ChatAttachment, context: ChatMediaContext) -> ChatMediaItemModel {
        let path: String
        switch attachment.source {
        case .agentPath(let p): path = p
        case .remote(let u): path = u
        }
        let key = ChatMediaItemModel.Key(conversation: context.conversation, scope: context.scope, id: attachment.id, path: path)
        if let known = models[key] {
            if known.attachment != attachment { known.attachment = attachment }
            return known
        }
        let created = ChatMediaItemModel(key: key, attachment: attachment)
        models[key] = created
        return created
    }

    /// The kind a row has: what the answer says now, held down by what the bytes allow. A file that turned out not to be
    /// what was claimed stays a document; a tag that arrives later (`[[as_document]]`) makes it one; voice and audio
    /// follow the current claim.
    nonisolated static func effectiveKind(claimed: ChatAttachmentKind, verified: ChatAttachmentKind?) -> ChatAttachmentKind {
        guard let verified else { return claimed }
        if verified == .document || claimed == .document { return .document }
        if (verified == .voice || verified == .audio) && (claimed == .voice || claimed == .audio) { return claimed }
        return verified
    }

    // MARK: Fetch

    /// Starts the fetch of a file of a sign in agent. `manual`: a click, so the cap is the manual one, nothing waits in
    /// the queue and the automatic budget does not apply. Does nothing when the row is already fetching or ready, or
    /// when the agent cannot be asked.
    func fetch(_ model: ChatMediaItemModel, context: ChatMediaContext, manual: Bool, thenSave: Bool = false) {
        guard context.canFetch, let agent = context.agent, case .agentPath(let path) = model.attachment.source else { return }
        if case .fetching = model.phase { model.saveWhenReady = model.saveWhenReady || thenSave; return }
        if case .ready = model.phase { return }
        let automatic = ChatMediaFetch.autoCap(for: model.attachment.kind)
        let cap = manual ? ChatMediaFetch.manualCap : (automatic ?? 0)
        guard cap > 0 else { return }
        model.saveWhenReady = thenSave
        model.automatic = !manual
        model.phase = .fetching(received: 0, total: nil)
        nextFetchID += 1
        let job = Job(model: model, agent: agent, path: path, cap: cap, conversation: context.conversation, automatic: !manual,
                      id: nextFetchID, received: ReceivedBytes())
        model.fetchID = job.id
        if manual { start(job) } else { queue.append(job); pump() }
    }

    /// Starts the waiting automatic fetches while there are places. A job that would take the conversation past its
    /// byte budget does not start: its row waits for a click.
    private func pump() {
        while running < maxConcurrent, !queue.isEmpty {
            let job = queue.removeFirst()
            if spent[job.conversation, default: 0] + job.cap > budget {
                job.model.automatic = false
                job.model.phase = .overBudget
                continue
            }
            spent[job.conversation, default: 0] += job.cap          // reserved until the real size is known
            running += 1
            start(job)
        }
    }

    private func start(_ job: Job) {
        let target = job.model
        let download = self.download
        let files = self.files
        let counter = job.received, id = job.id
        target.task = Task { [weak self] in
            let result = await download(job.agent, job.path, job.cap, files, job.conversation) { received, total in
                counter.note(received)
                // A tick that arrives late, after this fetch ended or was replaced by another, is not for the row any more.
                Task { @MainActor in
                    guard target.fetchID == id, case .fetching = target.phase else { return }
                    target.phase = .fetching(received: received, total: total)
                }
            }
            var verified: Verified?
            if case .success(let done) = result, !Task.isCancelled {
                let claimed = job.model.attachment.kind
                verified = await Task.detached(priority: .utility) { Self.verify(claimed: claimed, done: done) }.value
            }
            guard let self else { return }
            self.complete(job, result: result, verified: verified, cancelled: Task.isCancelled)
        }
    }

    private func complete(_ job: Job, result: Result<ChatMediaFetch.Downloaded, ChatMediaFetch.Failure>, verified: Verified?, cancelled: Bool) {
        if job.automatic {
            running = max(0, running - 1)
            // The reservation gives way to the bytes that really arrived, whatever came of them. Nothing to settle when
            // the conversation was cleared meanwhile (its count is gone).
            if let before = spent[job.conversation] {
                var received = job.received.value
                if case .success(let done) = result { received = max(received, done.bytes) }
                spent[job.conversation] = max(0, before - job.cap + received)
            }
        }
        let model = job.model
        if cancelled || models[model.key] !== model {
            // Gone while it ran: no row to show, and the bytes that arrived go with it.
            if case .success(let done) = result { files.remove(done.url) }
        } else {
            model.task = nil
            switch result {
            case .failure(let failure):
                if case .tooLarge(let size) = failure, job.automatic, (size ?? 0) <= ChatMediaFetch.manualCap {
                    model.phase = .needsClick(bytes: size)
                } else {
                    model.phase = .failed(failure)
                }
                model.saveWhenReady = false
            case .success:
                if let verified {
                    model.thumbnail = verified.thumbnail
                    model.phase = .ready(verified.ready)
                }
                // The click asked for a save, but the island folded while the bytes came: no panel and no activation
                // from nowhere. The row is ready and waits for the next click.
                if model.saveWhenReady { model.saveWhenReady = false; if chatShown() { save(model) } }
            }
            model.automatic = false
        }
        pump()
    }

    /// What the bytes allow, decided off the main actor (a file the agent chose can be a 12 000 pixel picture or a long
    /// recording): the type sniff, the audio probe, the image decode. Only the result comes back.
    struct Verified: @unchecked Sendable {
        let ready: ChatMediaItemModel.Ready
        let thumbnail: NSImage?
    }

    nonisolated static func verify(claimed: ChatAttachmentKind, done: ChatMediaFetch.Downloaded) -> Verified {
        let head = (try? Data(contentsOf: done.url, options: .mappedIfSafe)).map { [UInt8]($0.prefix(ChatMediaSniff.headBytes)) } ?? []
        var kind = ChatMediaSniff.verifiedKind(claimed: claimed, head: head).kind
        var duration: Double?
        var pixels: CGSize?
        var thumbnail: NSImage?
        // Only bytes with no signature can keep a plain data extension, and only when they really are text.
        let text = done.format == .unknown ? ChatMediaSniff.plainText(of: done.url) : ChatMediaSniff.PlainText.binary
        switch kind {
        case .voice, .audio:
            // A file that opens as audio plays; anything else is a document the person can save.
            if let seconds = ChatMediaPlayer.probe(done.url) { duration = seconds } else { kind = .document }
        case .image:
            if let image = decode(done.url) { thumbnail = image.thumbnail; pixels = image.pixels } else { kind = .document }
        case .video, .document:
            break
        }
        return Verified(ready: .init(url: done.url, kind: kind, format: done.format, bytes: done.bytes, duration: duration, pixels: pixels, text: text),
                        thumbnail: thumbnail)
    }

    /// The row draws a picture at most 300 pt wide: a thumbnail of twice that on the long side is enough for a screen
    /// with 2x pixels, and is what stays in memory. A declared size over 12 000 px a side is refused; SVG is never
    /// decoded (the sniff does not know it).
    nonisolated static let thumbnailPixels = 600

    nonisolated static func decode(_ url: URL) -> (thumbnail: NSImage, pixels: CGSize)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) >= 1,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              w >= 1, h >= 1, w <= 12_000, h <= 12_000 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // Drawn at half its pixels: the row is sharp on a 2x screen.
        return (NSImage(cgImage: cg, size: NSSize(width: Double(cg.width) / 2, height: Double(cg.height) / 2)), CGSize(width: w, height: h))
    }

    func rowAppeared(_ model: ChatMediaItemModel) { model.shownBy += 1 }

    /// A view of the row went away. When it was the last one (checked after the current update, so a view that replaces
    /// it counts), a fetch the row started by itself ends.
    func rowDisappeared(_ model: ChatMediaItemModel) {
        model.shownBy = max(0, model.shownBy - 1)
        guard model.shownBy == 0 else { return }
        Task { @MainActor [weak self, weak model] in
            guard let self, let model, model.shownBy == 0 else { return }
            self.cancelAutomatic(model)
        }
    }

    /// Ends the fetch of a row (it left the screen): queued or running, the bytes that arrive are dropped. A fetch the
    /// person started with a click is left to finish.
    func cancelAutomatic(_ model: ChatMediaItemModel) {
        guard model.automatic, case .fetching = model.phase else { return }
        if let at = queue.firstIndex(where: { $0.model === model }) {
            queue.remove(at: at)
        } else {
            model.task?.cancel()
        }
        model.task = nil
        model.automatic = false
        model.phase = nil
    }

    /// The chat left the screen (the island folded or hid): the sound pauses and the fetches the rows started stop. They
    /// start again, from the beginning, when the chat is back.
    func chatHidden() {
        pauseAll()
        for model in models.values { cancelAutomatic(model) }
    }

    /// "Try again": forgets the failure and asks again (or, for a sound that would not start, plays it again).
    func retry(_ model: ChatMediaItemModel, context: ChatMediaContext) {
        if case .failed(.cannotPlay) = model.phase, let ready = model.playable {
            model.playable = nil
            model.phase = .ready(ready)
            togglePlay(model)
            return
        }
        model.phase = nil
        fetch(model, context: context, manual: true)
    }

    // MARK: Playback

    func position(of model: ChatMediaItemModel) -> Double {
        guard model === active, let player else { return model.pausedAt }
        return player.currentTime
    }

    func togglePlay(_ model: ChatMediaItemModel) {
        guard case .ready(let ready) = model.phase, ready.kind == .voice || ready.kind == .audio else { return }
        if model === active, let player {
            if player.isPlaying { pause(model) } else { resume(model, player) }
            return
        }
        stopActive()
        guard let fresh = makePlayer(ready.url) else { couldNotPlay(model, ready); return }
        fresh.onFinish = { [weak self] in self?.finishedPlaying() }
        fresh.onInterrupted = { [weak self] in self?.interrupted() }
        player = fresh
        active = model
        model.pausedAt = 0
        resume(model, fresh)
    }

    private func resume(_ model: ChatMediaItemModel, _ player: any ChatMediaPlaying) {
        guard player.play() else {
            if case .ready(let ready) = model.phase { stopActive(); couldNotPlay(model, ready) }
            return
        }
        model.playing = true
    }

    /// The sound would not start: the row says so, with a way to try again, never a button that does nothing.
    private func couldNotPlay(_ model: ChatMediaItemModel, _ ready: ChatMediaItemModel.Ready) {
        model.playable = ready
        model.playing = false
        model.phase = .failed(.cannotPlay)
    }

    private func pause(_ model: ChatMediaItemModel) {
        guard model === active, let player else { return }
        player.pause()
        model.pausedAt = player.currentTime
        model.playing = false
    }

    private func stopActive() {
        if let active, let player {
            player.stop()
            active.pausedAt = 0
            active.playing = false
        }
        player = nil
        active = nil
    }

    /// The island folded or hid: the sound stops, the position stays. No timer and no engine run while paused.
    func pauseAll() {
        if let active { pause(active) }
    }

    /// Another conversation came on screen: the sound of this one pauses (the position stays).
    func conversationChanged(to conversation: String) {
        if let active, active.key.conversation != conversation { pause(active) }
    }

    private func finishedPlaying() {
        guard let active else { return }
        active.playing = false
        active.pausedAt = 0
        player = nil
        self.active = nil
    }

    private func interrupted() {
        guard let active, let player else { return }
        active.pausedAt = player.currentTime
        active.playing = false
    }

    // MARK: Save and open

    /// The save panel for a verified file. The suggested name is the agent's name made safe (`suggestedName`); the
    /// person decides where.
    func save(_ model: ChatMediaItemModel) {
        guard case .ready(let ready) = model.phase else { return }
        let files = self.files
        // After the click has returned: the panel runs its own loop (as `LinkConfirmation` does).
        let panel = self.savePanel
        DispatchQueue.main.async { [weak model] in
            MainActor.assumeIsolated {
                guard let model, let destination = panel(Self.suggestedName(model.attachment.name, format: ready.format, text: ready.text)) else { return }
                if files.save(ready.url, to: destination) {
                    model.saved = destination
                    model.saveFailed = false
                } else {
                    model.saveFailed = true
                }
            }
        }
    }

    /// The system save panel: the app comes forward and the person chooses. Nil when they cancel.
    private static func runSavePanel(suggestedName: String) -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Extensions that say what a file of that kind of bytes can be called. The extension of a saved file is ours: the
    /// agent's is kept only when the bytes agree with it.
    private nonisolated static func agrees(_ ext: String, with format: ChatMediaSniff.Format, text: ChatMediaSniff.PlainText) -> Bool {
        switch format {
        case .png: return ext == "png"
        case .jpeg: return ext == "jpg" || ext == "jpeg"
        case .gif: return ext == "gif"
        case .webp: return ext == "webp"
        case .bmp: return ext == "bmp"
        case .ogg: return ext == "ogg" || ext == "opus"
        case .mp3: return ext == "mp3" || ext == "m2a"
        case .wav: return ext == "wav"
        case .flac: return ext == "flac"
        case .mp4: return ["m4a", "mp4", "mov", "3gp"].contains(ext)
        case .matroska: return ext == "mkv" || ext == "webm"
        case .avi: return ext == "avi"
        case .pdf: return ext == "pdf"
        case .zip: return ["zip", "docx", "xlsx", "pptx", "odt", "ods", "odp", "epub", "kmz", "key"].contains(ext)
        // Bytes with no signature: only plain data formats that nothing runs or opens as a program, and only when the bytes
        // are text. `xml` is drawn by a browser (script in XHTML or SVG included): it is kept only for text that is not
        // markup, which no real XML file is.
        case .unknown:
            switch text {
            case .binary: return false
            case .text: return ["txt", "md", "csv", "tsv", "json", "xml", "yaml", "yml", "geojson", "kml", "gpx", "rtf"].contains(ext)
            case .markup: return ["txt", "md", "csv", "tsv", "json", "yaml", "yml", "geojson", "kml", "gpx", "rtf"].contains(ext)
            }
        }
    }

    /// The name of the saved file: `stem` and extension. The extension is the agent's when it is in the known list and
    /// agrees with the bytes, else the one the bytes have, else `bin`. Never anything the system would run or install.
    nonisolated static func saveParts(_ name: String, format: ChatMediaSniff.Format, text: ChatMediaSniff.PlainText = .binary) -> (stem: String, ext: String) {
        var clean = ChatMediaDirectives.readable(name, limit: Int.max)
        clean = String(clean.map { "/\\:".contains($0) ? "-" : $0 })
        while clean.hasPrefix(".") { clean.removeFirst() }
        clean = clean.trimmingCharacters(in: .whitespaces)
        var stem = clean
        var claimed = ""
        if let dot = clean.lastIndex(of: "."), dot != clean.startIndex {
            let candidate = String(clean[clean.index(after: dot)...]).lowercased()
            if !candidate.isEmpty, candidate.count <= 12, !candidate.contains(" ") {
                claimed = candidate
                stem = String(clean[..<dot])
            }
        }
        let ext = (ChatMediaDirectives.isKnownExtension(claimed) && agrees(claimed, with: format, text: text)) ? claimed : format.fileExtension
        stem = stem.trimmingCharacters(in: .whitespaces)
        // "Fatura.pdf" + a refused extension + the real "pdf" is "Fatura.pdf", not "Fatura.pdf.pdf".
        if stem.lowercased().hasSuffix("." + ext) { stem = String(stem.dropLast(ext.count + 1)).trimmingCharacters(in: .whitespaces) }
        if stem.isEmpty { stem = "file" }
        let room = max(1, 60 - ext.count - 1)
        if stem.count > room { stem = String(stem.prefix(room)).trimmingCharacters(in: .whitespaces) }
        return (stem.isEmpty ? "file" : stem, ext)
    }

    /// A name that is one plain file name: no folders, nothing hidden, no invisible or padding characters, at most 60
    /// characters, never empty, with an extension that is ours.
    nonisolated static func suggestedName(_ name: String, format: ChatMediaSniff.Format, text: ChatMediaSniff.PlainText = .binary) -> String {
        let parts = saveParts(name, format: format, text: text)
        return parts.stem + "." + parts.ext
    }

    /// The extension the saved file will have: what a row shows, so it never hides what the file really is.
    nonisolated static func finalExtension(_ name: String, format: ChatMediaSniff.Format, text: ChatMediaSniff.PlainText = .binary) -> String {
        saveParts(name, format: format, text: text).ext
    }

    func showInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// An image whose bytes were verified, opened by the system on a click.
    func open(_ model: ChatMediaItemModel) {
        guard case .ready(let ready) = model.phase, ready.kind == .image else { return }
        NSWorkspace.shared.open(ready.url)
    }

    // MARK: Cleaning

    /// A conversation was cleared or its agent removed: its rows, its sound, its fetches and its files go.
    func forgetConversation(_ conversation: String) {
        if let active, active.key.conversation == conversation { stopActive() }
        queue.removeAll { $0.model.key.conversation == conversation }
        for (key, model) in models where key.conversation == conversation {
            model.task?.cancel()
            models[key] = nil
        }
        spent[conversation] = nil
        files.removeConversation(conversation)
    }

    /// The app quits: the sound stops and every file of this launch is deleted.
    func shutdown() {
        stopActive()
        queue = []
        for model in models.values { model.task?.cancel() }
        models = [:]
        files.removeAll()
    }

    /// At launch: what a crashed run left behind goes away.
    func sweepStale() { files.sweepStale() }
}

// MARK: - Is the chat on screen

/// Whether the chat is on screen (the island open on the chat). A row fetches by itself only while it is, and the
/// sound and the fetches stop when it is not. Set by `AppState`; observed by the rows, which redraw only when it flips.
@MainActor
final class ChatMediaVisibility: ObservableObject {
    static let shared = ChatMediaVisibility()
    @Published private(set) var shown = false

    func set(_ value: Bool) {
        guard value != shown else { return }
        shown = value
        if !value { ChatMediaStore.shared.chatHidden() }
    }
}
