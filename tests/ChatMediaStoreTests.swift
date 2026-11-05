import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

// The store of the media rows: what a fetch turns into (ready, a document, waits for a click, failed), one player at a
// time, pause on fold with the position kept, a conversation cleared while a fetch runs, the queue and the byte budget of
// automatic fetches, the cancellation when the chat leaves, the names of a saved file. Against tests/fake_hermes_dashboard.py
// on 127.0.0.1 (nothing else is contacted) and a fake player (no audio device needed).

extension ChatMediaStore {
    // The store knows no global; the app makes its own next to `HermesSessions.shared`.
    static let shared = ChatMediaStore(sessions: HermesSessions(storage: HermesSessionStorage(load: { "" }, save: { _ in })))
}

@MainActor
final class FakePlayer: ChatMediaPlaying {
    var isPlaying = false
    var currentTime = 0.0
    var onFinish: (() -> Void)?
    var onInterrupted: (() -> Void)?
    var playResult = true
    var plays = 0, pauses = 0, stops = 0

    func play() -> Bool {
        plays += 1
        if playResult { isPlaying = true }
        return playResult
    }
    func pause() { pauses += 1; isPlaying = false }
    func stop() { stops += 1; isPlaying = false; currentTime = 0 }
}

@main
@MainActor
enum ChatMediaStoreTests {
    static var failures = 0
    static var base = ""

    static func check<T: Equatable>(_ label: String, _ got: T, _ expected: T) {
        if got == expected { print("  ok   \(label)") } else { print("  FAIL \(label)\n    got:      \(got)\n    expected: \(expected)"); failures += 1 }
    }
    static func checkTrue(_ label: String, _ value: Bool) {
        if value { print("  ok   \(label)") } else { print("  FAIL \(label)"); failures += 1 }
    }

    // MARK: Server helpers

    static func ctl(_ path: String, _ json: [String: Any] = [:]) async {
        var req = URLRequest(url: URL(string: base + path)!)
        req.httpMethod = "POST"
        req.httpBody = try? JSONSerialization.data(withJSONObject: json)
        _ = try? await URLSession.shared.data(for: req)
    }

    static func state() async -> [String: Any] {
        guard let (d, _) = try? await URLSession.shared.data(from: URL(string: base + "/_test/state")!),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return j
    }

    static func int(_ s: [String: Any], _ k: String) -> Int { (s[k] as? NSNumber)?.intValue ?? -1 }

    final class Mem: @unchecked Sendable {
        let lock = NSLock()
        var v = ""
        var value: String { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
    }

    static func agent(_ connection: HermesConnection? = .signIn) -> HermesAgent {
        HermesAgent(name: "steve", baseURL: base, profile: "codex", modelName: "", connection: connection)
    }

    static func makeSessions() async -> HermesSessions? {
        let mem = Mem()
        let sessions = HermesSessions(storage: HermesSessionStorage(load: { mem.value }, save: { mem.value = $0 }))
        let r = await HermesSignInNet.signIn(baseURL: base, timeout: 10) { url in Task { _ = try? await URLSession.shared.data(from: url) } }
        guard case .success(var rec) = r else { return nil }
        rec.label = "Test User"
        await sessions.store(rec, name: "steve")
        return sessions
    }

    static func mode(_ m: String, size: Int = 1 << 20, delay: Double = 0) async {
        await ctl("/_test/config", ["files_mode": m, "files_size": size, "files_delay": delay, "files_401": 0])
    }

    static func waitUntil(_ timeout: Double, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return cond()
    }

    static func tempBase() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("coucou-media-store-test-" + UUID().uuidString, isDirectory: true)
    }

    static func regularFiles(in root: URL) -> [String] {
        let fm = FileManager.default
        guard let all = fm.subpathsOfDirectory(atPathOrNil: root.path) else { return [] }
        // The `owner` file of a launch folder is bookkeeping, not a fetched file.
        return all.filter { var d: ObjCBool = false; return fm.fileExists(atPath: root.appendingPathComponent($0).path, isDirectory: &d) && !d.boolValue && !$0.hasSuffix("/owner") }
    }

    static func attachment(_ id: Int, _ kind: ChatAttachmentKind, _ path: String? = nil) -> ChatAttachment {
        ChatAttachment(id: id, kind: kind, source: .agentPath(path ?? "/tmp/f\(id).bin"), name: "f\(id)")
    }

    static func context(_ conversation: String = "c1", connection: HermesConnection? = .signIn) -> ChatMediaContext {
        ChatMediaContext(enabled: true, conversation: conversation, agent: agent(connection), agentName: "Steve", colorHex: "#F97316", scope: "s")
    }

    static func phaseIsReady(_ model: ChatMediaItemModel) -> ChatMediaItemModel.Ready? {
        if case .ready(let r) = model.phase { return r }
        return nil
    }

    static func makeStore(_ sessions: HermesSessions, files: ChatMediaFiles, maxConcurrent: Int = 2, budget: Int? = nil,
                          players: PlayerBox? = nil, download: ChatMediaStore.Download? = nil,
                          chatShown: (@MainActor () -> Bool)? = nil, savePanel: (@MainActor (String) -> URL?)? = nil) -> ChatMediaStore {
        ChatMediaStore(sessions: sessions, files: files, maxConcurrent: maxConcurrent, automaticBudget: budget,
                       makePlayer: { _ in players?.make() }, download: download, chatShown: chatShown, savePanel: savePanel)
    }

    /// Remembers what a fake download was asked, and hands its progress callback to the test.
    final class Tap: @unchecked Sendable {
        private let lock = NSLock()
        private var ticks: [@Sendable (Int, Int?) -> Void] = []
        private var asked = 0
        func note(_ tick: @escaping @Sendable (Int, Int?) -> Void) { lock.withLock { ticks.append(tick); asked += 1 } }
        var count: Int { lock.withLock { asked } }
        func tick(_ index: Int) -> (@Sendable (Int, Int?) -> Void)? { lock.withLock { index < ticks.count ? ticks[index] : nil } }
    }

    @MainActor
    final class PlayerBox {
        var made: [FakePlayer] = []
        var failPlay = false
        var refuse = false
        func make() -> FakePlayer? {
            if refuse { return nil }
            let p = FakePlayer()
            p.playResult = !failPlay
            made.append(p)
            return p
        }
    }

    /// A picture of the given size, as PNG bytes in a file.
    static func makePNG(width: Int, height: Int) -> URL? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = ctx.makeImage() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("coucou-big-\(UUID().uuidString).png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? url : nil
    }

    // MARK: Tests

    static func main() async {
        base = "http://127.0.0.1:\(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "0")"
        print("ChatMediaStore")
        let fm = FileManager.default

        // ── Pure: the kind of a row, the name of a saved file, the thumbnail size ──
        let K = ChatMediaStore.effectiveKind
        checkTrue("01 the kind of a row follows the answer as it stands now, held down by the bytes", {
            K(.voice, nil) == .voice && K(.image, .image) == .image && K(.image, .document) == .document
                && K(.document, .image) == .document          // [[as_document]] came after the image was shown
                && K(.audio, .voice) == .audio && K(.voice, .audio) == .voice           // the voice tag arrived later / went
                && K(.voice, .document) == .document && K(.video, .video) == .video
        }())

        let S = { (name: String, f: ChatMediaSniff.Format) in ChatMediaStore.suggestedName(name, format: f) }
        let ST = { (name: String, f: ChatMediaSniff.Format, t: ChatMediaSniff.PlainText) in ChatMediaStore.suggestedName(name, format: f, text: t) }
        let blanks = String(repeating: "\u{2800}", count: 60), spaces = String(repeating: " ", count: 80)
        checkTrue("02 the saved extension is ours: a refused one is replaced by what the bytes are, or bin", {
            S("report.command", .unknown) == "report.bin"
                && S("Fatura.pdf.terminal", .pdf) == "Fatura.pdf"
                && S("Fatura.pdf" + blanks + ".terminal", .pdf) == "Fatura.pdf"
                && S("Fatura.pdf" + spaces + ".inetloc", .pdf) == "Fatura.pdf"
                && S("setup.app", .unknown) == "setup.bin" && S("x.webloc", .unknown) == "x.bin"
                && S("x.mobileconfig", .unknown) == "x.bin" && S("installer.pkg", .unknown) == "installer.bin"
                && S("installer.pkg", .zip) == "installer.zip"
        }())
        checkTrue("02b the agent's extension is kept only when it is known and agrees with the bytes", {
            S("photo.png", .png) == "photo.png" && S("foto.jpeg", .jpeg) == "foto.jpeg" && S("foto.JPG", .jpeg) == "foto.jpg"
                && S("photo.png", .unknown) == "photo.bin" && S("photo.png", .pdf) == "photo.pdf"
                && ST("notes.txt", .unknown, .text) == "notes.txt" && ST("data.csv", .unknown, .text) == "data.csv"
                && S("page.html", .unknown) == "page.bin" && S("image.svg", .unknown) == "image.bin"
                && S("cartao.docx", .zip) == "cartao.docx" && S("app.ipa", .zip) == "app.zip" && S("voice.opus", .ogg) == "voice.opus"
        }())
        checkTrue("02c nothing the system would run or install is ever suggested, whatever the name and the bytes", {
            let bad: Set<String> = ["app", "command", "terminal", "inetloc", "webloc", "mobileconfig", "pkg", "dmg", "workflow", "action",
                                    "scpt", "sh", "js", "exe", "bat", "jar", "vbs", "ps1", "scr", "pif", "ipa", "apk", "html", "htm", "svg"]
            let formats: [ChatMediaSniff.Format] = [.png, .jpeg, .gif, .webp, .bmp, .ogg, .mp3, .wav, .flac, .mp4, .matroska, .avi, .pdf, .zip, .unknown]
            for ext in bad {
                for format in formats {
                    let out = S("name.\(ext)", format)
                    let got = (out as NSString).pathExtension
                    if bad.contains(got) { print("    suggested \(out) for \(ext) / \(format)"); return false }
                    let padded = S("name.pdf" + blanks + ".\(ext)", format)
                    if bad.contains((padded as NSString).pathExtension) { return false }
                }
            }
            return true
        }())
        checkTrue("02d one plain name: no folders, nothing hidden, no invisible or padding character, at most 60 characters, never empty", {
            let a = S("../../.ssh/id_rsa.png", .png), b = S("a:b/c\\d.png", .png), c = S("", .unknown), d = S("   ", .png)
            let long = S(String(repeating: "x", count: 200) + ".png", .png)
            let e = S("ab\u{202E}fdp\u{200B}.png", .png), f = S("a\u{2800}\u{2800} \t b.png", .png)
            return !a.contains("/") && !a.hasPrefix(".") && a.hasSuffix(".png") && b == "a-b-c-d.png" && c == "file.bin" && d == "file.png"
                && long.count == 60 && long.hasSuffix(".png") && e == "abfdp.png" && f == "a b.png"
        }())

        // Aegis B3: bytes with no signature keep a plain data extension only when they are text, and `xml` only for text
        // that is not markup.
        checkTrue("02f a plain data extension is kept only for bytes that are text; xml only for text that is not markup", {
            ST("page.xml", .unknown, .markup) == "page.bin" && ST("pic.xml", .unknown, .markup) == "pic.bin"
                && ST("x.xml", .unknown, .binary) == "x.bin" && ST("notes.xml", .unknown, .text) == "notes.xml"
                && ST("data.csv", .unknown, .binary) == "data.bin" && ST("a.json", .unknown, .binary) == "a.bin"
                && ST("page.rtf", .unknown, .markup) == "page.rtf" && ST("data.csv", .unknown, .markup) == "data.csv"
                && ST("run.txt", .unknown, .text) == "run.txt" && ST("page.html", .unknown, .text) == "page.bin"
                && ST("pic.svg", .unknown, .markup) == "pic.bin"
                && ChatMediaStore.finalExtension("x.xml", format: .unknown, text: .markup) == "bin"
        }())
        checkTrue("02g ...and the plumbing reads the real bytes of a fetched file", {
            func ext(_ name: String, _ bytes: [UInt8]) -> String {
                let url = fm.temporaryDirectory.appendingPathComponent("coucou-text-\(UUID().uuidString)")
                try? Data(bytes).write(to: url)
                defer { try? fm.removeItem(at: url) }
                let done = ChatMediaFetch.Downloaded(url: url, format: ChatMediaSniff.format(of: Array(bytes.prefix(32))), bytes: bytes.count)
                let ready = ChatMediaStore.verify(claimed: .document, done: done).ready
                return ChatMediaStore.suggestedName(name, format: ready.format, text: ready.text)
            }
            let utf16: [UInt8] = [0xFF, 0xFE, 0x61, 0x00, 0x2C, 0x00, 0x62, 0x00]
            return ext("a.csv", Array("a,b\n1,2\n".utf8)) == "a.csv"
                && ext("a.csv", [0x61, 0x2C, 0x00, 0x62]) == "a.bin"                         // a NUL byte
                && ext("a.csv", [0x61, 0xFF, 0xFE, 0x62]) == "a.bin"                         // not UTF-8
                && ext("a.csv", utf16) == "a.bin"                                              // UTF-16 text (and not MP3)
                && ext("page.xml", Array("<?xml version=\"1.0\"?><html><script>alert(1)</script></html>".utf8)) == "page.bin"
                && ext("page.xml", Array("  \n<svg onload=alert(1)>".utf8)) == "page.bin"
                && ext("x.xml", Array("\u{FEFF}<plist/>".utf8)) == "x.bin"
                && ext("page.rtf", Array("<html>".utf8)) == "page.rtf"
        }())

        checkTrue("02e one sentence per state: one string each, no size when it is not known, nothing joined", {
            ChatMediaWords.unavailable(agentName: "Steve") == "This file is on Steve's computer. This connection cannot reach it."
                && ChatMediaWords.unavailable(agentName: "") == "This file is on the agent's computer. This connection cannot reach it."
                && ChatMediaWords.tooLarge(bytes: 6 << 20) == "\(ChatMediaWords.size(6 << 20)) · too large to fetch by itself"
                && ChatMediaWords.tooLarge(bytes: nil) == "Too large to fetch by itself."
                && ChatMediaWords.fetching(fraction: 0.62) == "Fetching · 62 %" && ChatMediaWords.fetching(fraction: nil) == "Fetching…"
                && ChatMediaWords.fetching(fraction: 7) == "Fetching · 100 %"
                && !ChatMediaWords.tooLarge(bytes: nil).contains("50")
                && ChatMediaWords.overBudget() == "Waiting for a click: this conversation already fetched a lot."
                && !ChatMediaWords.overBudget().lowercased().contains("large") && !ChatMediaWords.overBudget().contains("MB")
                && ChatMediaWords.saveFailed() == "Could not save the file."
        }())

        checkTrue("03 the extension a row shows is the final one", {
            ChatMediaStore.finalExtension("Fatura.pdf.terminal", format: .pdf) == "pdf" && ChatMediaStore.finalExtension("x.command", format: .unknown) == "bin"
                && ChatMediaStore.finalExtension("a.png", format: .png) == "png"
        }())

        if let big = makePNG(width: 3000, height: 2000) {
            defer { try? fm.removeItem(at: big) }
            let decoded = ChatMediaStore.decode(big)
            // The image is made at half its pixels (2x), so its size gives the pixels without asking a representation,
            // which a machine with no screen may not report.
            let longSide = decoded.map { Int((max($0.thumbnail.size.width, $0.thumbnail.size.height) * 2).rounded()) } ?? 0
            check("04 a thumbnail is decoded at twice the drawn size (600 px), not 1600", "\(longSide) \(decoded?.pixels ?? .zero)", "600 \(CGSize(width: 3000, height: 2000))")
        } else {
            checkTrue("04 could not make the test picture", false)
        }

        // ── Playback with a fake player ──
        await ctl("/_test/reset")
        guard let sessions = await makeSessions() else { print("  FAIL sign in against the fake"); exit(1) }
        let root = tempBase()
        defer { try? fm.removeItem(at: root) }
        let files = ChatMediaFiles(base: root)
        let none: @Sendable (Int, Int?) -> Void = { _, _ in }
        _ = none

        await mode("realwav")
        let players = PlayerBox()
        let store = makeStore(sessions, files: files, players: players)
        let ctx = context()
        let a = store.model(for: attachment(0, .voice, "/tmp/a.wav"), context: ctx)
        let b = store.model(for: attachment(1, .audio, "/tmp/b.wav"), context: ctx)
        store.fetch(a, context: ctx, manual: false)
        store.fetch(b, context: ctx, manual: false)
        let loaded = await waitUntil(10) { phaseIsReady(a) != nil && phaseIsReady(b) != nil }
        checkTrue("10 a voice note and an audio file fetched by themselves become ready rows with a duration from the bytes",
                  loaded && phaseIsReady(a)?.kind == .voice && phaseIsReady(b)?.kind == .audio && abs((phaseIsReady(a)?.duration ?? 0) - 0.5) < 0.05)

        store.togglePlay(a)
        let first = players.made.first
        checkTrue("11 play starts one player and the row says so", a.playing && first?.isPlaying == true && players.made.count == 1)
        first?.currentTime = 1.25
        store.togglePlay(b)
        checkTrue("12 one player at a time: playing another row stops the first (position back to the start) and starts a new player", {
            !a.playing && a.pausedAt == 0 && first?.isPlaying == false && (first?.stops ?? 0) == 1 && b.playing && players.made.count == 2
                && players.made.filter(\.isPlaying).count == 1
        }())
        let second = players.made[1]
        second.currentTime = 1.5
        store.chatHidden()
        checkTrue("13 the island folds: the sound pauses and the position stays", !b.playing && b.pausedAt == 1.5 && !second.isPlaying && second.pauses == 1)
        check("13b ...and the row reads that position while paused", store.position(of: b), 1.5)
        store.togglePlay(b)
        checkTrue("13c ...playing again resumes the same player, no new one", b.playing && second.isPlaying && players.made.count == 2 && second.plays == 2)
        store.conversationChanged(to: "c1")
        checkTrue("14 the same conversation on screen does not touch the sound", b.playing)
        second.currentTime = 2.0
        store.conversationChanged(to: "another conversation")
        checkTrue("14b another conversation on screen pauses the sound and keeps the position", !b.playing && b.pausedAt == 2.0 && !second.isPlaying)
        store.togglePlay(b)
        second.onFinish?()
        checkTrue("15 a sound that reaches its end goes back to the start and is not playing", !b.playing && b.pausedAt == 0)
        store.togglePlay(b)
        checkTrue("15b ...and the next play builds a new player", players.made.count == 3 && b.playing)
        store.chatHidden()

        // A sound that would not start: the failed state, never a dead button
        players.failPlay = true
        store.togglePlay(a)
        checkTrue("16 an engine that fails to start shows the failed state, not a button that does nothing", {
            if case .failed(.cannotPlay) = a.phase { return !a.playing }
            return false
        }())
        players.failPlay = false
        store.retry(a, context: ctx)
        checkTrue("16b ...and Try again plays it", phaseIsReady(a) != nil && a.playing)
        store.chatHidden()
        players.refuse = true
        store.togglePlay(b)
        checkTrue("16c a player that cannot even open the file fails the same way", { if case .failed(.cannotPlay) = b.phase { return true }; return false }())
        players.refuse = false

        // The row takes its kind from the current attachment
        let again = store.model(for: attachment(0, .audio, "/tmp/a.wav"), context: ctx)
        checkTrue("17 the same row with a later claim (the voice tag went) is the same model with the new kind", again === a && again.attachment.kind == .audio)

        // ── What a fetch turns into ──
        await ctl("/_test/reset")
        guard let sessions2 = await makeSessions() else { exit(1) }
        func fresh(_ s: HermesSessions? = nil, maxConcurrent: Int = 2, budget: Int? = nil, download: ChatMediaStore.Download? = nil,
                   chatShown: (@MainActor () -> Bool)? = nil, savePanel: (@MainActor (String) -> URL?)? = nil) -> (ChatMediaStore, ChatMediaFiles, URL) {
            let r = tempBase()
            let f = ChatMediaFiles(base: r)
            return (makeStore(s ?? sessions2, files: f, maxConcurrent: maxConcurrent, budget: budget, players: PlayerBox(), download: download,
                              chatShown: chatShown, savePanel: savePanel), f, r)
        }

        await mode("ok")
        let (st, _, rt) = fresh()
        defer { try? fm.removeItem(at: rt) }
        var m = st.model(for: attachment(0, .voice, "/tmp/x.ogg"), context: ctx)
        st.fetch(m, context: ctx, manual: false)
        _ = await waitUntil(10) { phaseIsReady(m) != nil }
        checkTrue("20 bytes that are not audio behind a voice claim demote the row to a document the person can save", {
            guard let r = phaseIsReady(m) else { return false }
            return r.kind == .document && r.format == .ogg && ChatMediaStore.effectiveKind(claimed: .voice, verified: r.kind) == .document
        }())

        await mode("realpng")
        m = st.model(for: attachment(1, .image, "/tmp/x.png"), context: ctx)
        st.fetch(m, context: ctx, manual: false)
        _ = await waitUntil(10) { phaseIsReady(m) != nil }
        checkTrue("21 a real picture becomes an image row with its size and a thumbnail", {
            guard let r = phaseIsReady(m) else { return false }
            return r.kind == .image && r.pixels == CGSize(width: 8, height: 8) && m.thumbnail != nil
        }())

        await mode("png")
        m = st.model(for: attachment(2, .image, "/tmp/y.png"), context: ctx)
        st.fetch(m, context: ctx, manual: false)
        _ = await waitUntil(10) { phaseIsReady(m) != nil }
        checkTrue("21b a picture that does not decode is a document", phaseIsReady(m)?.kind == .document && m.thumbnail == nil)

        await mode("big", size: 6 << 20)
        m = st.model(for: attachment(3, .image, "/tmp/big.png"), context: ctx)
        st.fetch(m, context: ctx, manual: false)
        _ = await waitUntil(10) { if case .fetching = m.phase { return false }; return true }
        check("22 a file over the automatic cap with a declared size waits for a click, with that size", m.phase, .needsClick(bytes: 6 << 20))
        st.fetch(m, context: ctx, manual: true)
        _ = await waitUntil(15) { phaseIsReady(m) != nil }
        checkTrue("22b ...and the click fetches it", phaseIsReady(m)?.bytes == 6 << 20)

        await mode("413")
        m = st.model(for: attachment(4, .image, "/tmp/413.png"), context: ctx)
        st.fetch(m, context: ctx, manual: false)
        _ = await waitUntil(10) { if case .fetching = m.phase { return false }; return true }
        check("22c a refusal for size with no size waits for a click and shows no size", m.phase, .needsClick(bytes: nil))

        await mode("declared_big")
        m = st.model(for: attachment(5, .voice, "/tmp/huge.ogg"), context: ctx)
        st.fetch(m, context: ctx, manual: false)
        _ = await waitUntil(10) { if case .fetching = m.phase { return false }; return true }
        check("22d a size over even the click cap is a failure, not a button", m.phase, .failed(.tooLarge(200 << 20)))

        await mode("404")
        m = st.model(for: attachment(6, .voice, "/tmp/gone.ogg"), context: ctx)
        st.fetch(m, context: ctx, manual: false)
        _ = await waitUntil(10) { if case .fetching = m.phase { return false }; return true }
        check("22e a missing file is a failure", m.phase, .failed(.notFound))

        await ctl("/_test/reset")
        guard let sessions3 = await makeSessions() else { exit(1) }
        let apiCtx = context(connection: .apiKey)
        let (st2, _, rt2) = fresh(sessions3)
        defer { try? fm.removeItem(at: rt2) }
        let apiModel = st2.model(for: attachment(0, .voice, "/tmp/a.ogg"), context: apiCtx)
        st2.fetch(apiModel, context: apiCtx, manual: false)
        st2.fetch(apiModel, context: apiCtx, manual: true)
        try? await Task.sleep(nanoseconds: 300_000_000)
        let s30 = await state()
        checkTrue("23 an API key agent: no request at all, the row stays as it was", apiModel.phase == nil && ((s30["downloads"] as? [Any]) ?? []).isEmpty)

        // ── A conversation cleared while a fetch runs leaves no file ──
        await ctl("/_test/reset")
        guard let sessions4 = await makeSessions() else { exit(1) }
        await mode("realwav", delay: 1.0)
        let (st3, fl3, rt3) = fresh(sessions4)
        defer { try? fm.removeItem(at: rt3) }
        let slow = st3.model(for: attachment(0, .voice, "/tmp/slow.wav"), context: ctx)
        st3.fetch(slow, context: ctx, manual: false)
        let started = await waitUntil(5) { true }
        _ = started
        let sawRequest = await waitUntilAsync(5) { int(await state(), "files_inflight") >= 1 }
        st3.forgetConversation("c1")
        try? await Task.sleep(nanoseconds: 1_800_000_000)
        checkTrue("30 clearing the conversation while its fetch runs cancels it and leaves no file on disk", sawRequest
                  && regularFiles(in: rt3).isEmpty && slow.task?.isCancelled == true)
        checkTrue("30b ...and the row is gone: asking for it again makes a new one", st3.model(for: attachment(0, .voice, "/tmp/slow.wav"), context: ctx) !== slow)
        _ = fl3

        // ── The queue: two at a time ──
        await ctl("/_test/reset")
        guard let sessions5 = await makeSessions() else { exit(1) }
        await mode("realwav", delay: 0.4)
        let (st4, _, rt4) = fresh(sessions5)
        defer { try? fm.removeItem(at: rt4) }
        let rows = (0..<6).map { st4.model(for: attachment($0, .audio, "/tmp/q\($0).wav"), context: ctx) }
        for row in rows { st4.fetch(row, context: ctx, manual: false) }
        let allReady = await waitUntil(20) { rows.allSatisfy { phaseIsReady($0) != nil } }
        let s31 = await state()
        checkTrue("31 six rows fetch by themselves two at a time: all become ready, the server never saw more than two together",
                  allReady && int(s31, "files_max_inflight") == 2)

        // ── The byte budget of automatic fetches ──
        await ctl("/_test/reset")
        guard let sessions6 = await makeSessions() else { exit(1) }
        await mode("big", size: 4 << 20)
        let (st5, _, rt5) = fresh(sessions6, budget: 12 << 20)
        defer { try? fm.removeItem(at: rt5) }
        let pics = (0..<4).map { st5.model(for: attachment($0, .image, "/tmp/p\($0).png"), context: ctx) }
        for p in pics { st5.fetch(p, context: ctx, manual: false) }
        _ = await waitUntil(20) { pics.allSatisfy { if case .fetching = $0.phase { return false }; return $0.phase != nil } }
        let readyCount = pics.filter { phaseIsReady($0) != nil }.count
        let waiting = pics.filter { $0.phase == .overBudget }.count
        checkTrue("32 the budget reserves the cap of each started fetch (5 MB for a picture): with 4 MB files in a 12 MB budget 2 are fetched and 2 wait for a click, in their own state (not 'too large')",
                  readyCount == 2 && waiting == 2 && !pics.contains { $0.phase == .needsClick(bytes: nil) })
        let waited = pics.first { $0.phase == .overBudget }
        if let waited {
            st5.fetch(waited, context: ctx, manual: true)
            let ok = await waitUntil(15) { phaseIsReady(waited) != nil }
            checkTrue("32b ...and a click is not held to the budget", ok)
        }
        let other = context("c2")
        let elsewhere = st5.model(for: attachment(0, .image, "/tmp/other.png"), context: other)
        st5.fetch(elsewhere, context: other, manual: false)
        let ok2 = await waitUntil(15) { phaseIsReady(elsewhere) != nil }
        checkTrue("32c ...the budget is per conversation: another conversation still fetches by itself", ok2)

        // ── Cancellation when the chat leaves, and when the row goes ──
        await ctl("/_test/reset")
        guard let sessions7 = await makeSessions() else { exit(1) }
        await mode("realwav", delay: 0.8)
        let (st6, _, rt6) = fresh(sessions7, maxConcurrent: 1)
        defer { try? fm.removeItem(at: rt6) }
        let autoRows = (0..<3).map { st6.model(for: attachment($0, .audio, "/tmp/c\($0).wav"), context: ctx) }
        for r in autoRows { st6.fetch(r, context: ctx, manual: false) }
        let docRow = st6.model(for: attachment(9, .document, "/tmp/clicked.pdf"), context: ctx)
        st6.fetch(docRow, context: ctx, manual: true)       // a click on Save…
        _ = await waitUntilAsync(5) { int(await state(), "files_inflight") >= 1 }
        st6.chatHidden()
        checkTrue("33 the chat leaves: the fetches the rows started stop (running and queued), the rows go back to nothing",
                  autoRows.allSatisfy { $0.phase == nil && $0.task == nil })
        let docDone = await waitUntil(15) { phaseIsReady(docRow) != nil }
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        checkTrue("33b ...a fetch started by a click may finish", docDone)
        checkTrue("33c ...and what the cancelled fetches received is not kept: only the clicked file is on disk", regularFiles(in: rt6).count == 1)
        st6.fetch(autoRows[0], context: ctx, manual: false)
        let back = await waitUntil(15) { phaseIsReady(autoRows[0]) != nil }
        checkTrue("33d ...and when the chat is back a row fetches again from the start", back)

        await mode("realwav", delay: 0.8)
        let gone = st6.model(for: attachment(20, .audio, "/tmp/gone.wav"), context: ctx)
        st6.fetch(gone, context: ctx, manual: false)
        _ = await waitUntilAsync(5) { int(await state(), "files_inflight") >= 1 }
        st6.cancelAutomatic(gone)
        checkTrue("34 a row that disappears ends its own fetch", gone.phase == nil && gone.task == nil)
        // The views of a row come and go as the card is laid out again: only the last one leaving ends the fetch.
        await mode("realwav", delay: 0.8)
        let moved = st6.model(for: attachment(21, .audio, "/tmp/moved.wav"), context: ctx)
        st6.rowAppeared(moved)
        st6.fetch(moved, context: ctx, manual: false)
        _ = await waitUntilAsync(5) { int(await state(), "files_inflight") >= 1 }
        st6.rowAppeared(moved)              // the new view of the row is built first...
        st6.rowDisappeared(moved)           // ...then the old one goes
        try? await Task.sleep(nanoseconds: 100_000_000)
        checkTrue("34c a row whose view was replaced keeps its fetch", { if case .fetching = moved.phase { return true }; return false }())
        st6.rowDisappeared(moved)           // the last view goes
        try? await Task.sleep(nanoseconds: 100_000_000)
        checkTrue("34d ...and ends it when the last view is gone", moved.phase == nil && moved.task == nil)

        let readyAgain = st6.model(for: attachment(0, .audio, "/tmp/c0.wav"), context: ctx)
        st6.cancelAutomatic(readyAgain)
        checkTrue("34b ...and a row that is already ready is left alone", phaseIsReady(readyAgain) != nil)

        // ── Aegis B1: the bytes that reached the app count in the budget, whatever came of them ──
        let bctx = context("bytes")
        let failingAfter4MB: ChatMediaStore.Download = { _, _, _, _, _, progress in
            progress(4 << 20, nil)
            return .failure(.network)
        }
        let (stF, _, rtF) = fresh(maxConcurrent: 1, budget: 12 << 20, download: failingAfter4MB)
        defer { try? fm.removeItem(at: rtF) }
        let failRows = (0..<3).map { stF.model(for: attachment($0, .image, "/tmp/fail\($0).png"), context: bctx) }
        for r in failRows { stF.fetch(r, context: bctx, manual: false) }
        _ = await waitUntil(5) { failRows.allSatisfy { $0.phase != nil } && !failRows.contains { if case .fetching = $0.phase { return true }; return false } }
        check("35 a fetch that failed after 4 MB costs those 4 MB: the third picture (4 + 4 + 5 MB reserved > 12 MB) waits for a click",
              failRows.map { $0.phase.map { "\($0)" } ?? "nil" }.map { $0.hasPrefix("failed") ? "failed" : $0 },
              ["failed", "failed", "overBudget"])

        let cutAtCap: ChatMediaStore.Download = { _, _, cap, _, _, progress in
            progress(cap + 65_536, nil)
            return .failure(.tooLarge(nil))
        }
        let (stC, _, rtC) = fresh(maxConcurrent: 1, budget: 30 << 20, download: cutAtCap)
        defer { try? fm.removeItem(at: rtC) }
        let cutRows = (0..<5).map { stC.model(for: attachment($0, .audio, "/tmp/cut\($0).wav"), context: bctx) }
        for r in cutRows { stC.fetch(r, context: bctx, manual: false) }
        _ = await waitUntil(5) { cutRows.allSatisfy { if case .fetching = $0.phase { return false }; return $0.phase != nil } }
        check("35b a fetch cut for size costs the bytes that came: two cut at 10 MB use the 30 MB budget, the rest wait",
              cutRows.map { row -> String in
                  switch row.phase {
                  case .some(.needsClick(bytes: nil)): return "needsClick"
                  case .some(.overBudget): return "overBudget"
                  default: return "other"
                  }
              }, ["needsClick", "needsClick", "overBudget", "overBudget", "overBudget"])

        let hangs: ChatMediaStore.Download = { _, _, _, _, _, progress in
            progress(4 << 20, nil)
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
            return .failure(.network)
        }
        let (stX, _, rtX) = fresh(maxConcurrent: 1, budget: 6 << 20, download: hangs)
        defer { try? fm.removeItem(at: rtX) }
        let xa = stX.model(for: attachment(0, .image, "/tmp/xa.png"), context: bctx), xb = stX.model(for: attachment(1, .image, "/tmp/xb.png"), context: bctx)
        stX.fetch(xa, context: bctx, manual: false)
        try? await Task.sleep(nanoseconds: 150_000_000)
        stX.cancelAutomatic(xa)
        try? await Task.sleep(nanoseconds: 150_000_000)
        stX.fetch(xb, context: bctx, manual: false)
        try? await Task.sleep(nanoseconds: 100_000_000)
        checkTrue("35c a fetch cancelled after 4 MB costs them too: the next picture (4 + 5 MB reserved > 6 MB) waits for a click", xb.phase == .overBudget)

        let clean: ChatMediaStore.Download = { _, _, _, files, conversation, progress in
            progress(1000, 1000)
            guard let url = files.write(Data(count: 1000), conversation: conversation, extensionName: "bin") else { return .failure(.unreadable) }
            return .success(.init(url: url, format: .unknown, bytes: 1000))
        }
        let (stS, _, rtS) = fresh(maxConcurrent: 1, budget: 6 << 20, download: clean)
        defer { try? fm.removeItem(at: rtS) }
        let sRows = (0..<4).map { stS.model(for: attachment($0, .image, "/tmp/ok\($0).png"), context: bctx) }
        for r in sRows { stS.fetch(r, context: bctx, manual: false) }
        _ = await waitUntil(5) { sRows.allSatisfy { if case .fetching = $0.phase { return false }; return $0.phase != nil } }
        checkTrue("35d a fetch that succeeds gives back its reservation and costs only its bytes: four small pictures all go through a 6 MB budget",
                  !sRows.contains { $0.phase == .overBudget })

        // The real server: an answer with no length that never ends (the cut at the cap) uses up the budget for real.
        await ctl("/_test/reset")
        guard let sessions8 = await makeSessions() else { exit(1) }
        await mode("endless")
        let (stE, _, rtE) = fresh(sessions8, maxConcurrent: 1, budget: 30 << 20)
        defer { try? fm.removeItem(at: rtE) }
        let endless = (0..<5).map { stE.model(for: attachment($0, .audio, "/tmp/endless\($0).ogg"), context: bctx) }
        for r in endless { stE.fetch(r, context: bctx, manual: false) }
        _ = await waitUntil(40) { endless.allSatisfy { $0.phase != nil && !{ if case .fetching = $0.phase { return true }; return false }($0) } }
        let endlessOver = endless.filter { $0.phase == .overBudget }.count
        let st8 = await state()
        checkTrue("35e the server that never ends: two rows are cut at 10 MB, the other three wait for a click and are never requested",
                  endlessOver == 3 && ((st8["downloads"] as? [Any])?.count ?? -1) == 2)

        // ── Late progress tick (Hera nit) ──
        let tap = Tap()
        let slowTicks: ChatMediaStore.Download = { _, _, _, _, _, progress in
            tap.note(progress)
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
            return .failure(.network)
        }
        let (stT, _, rtT) = fresh(maxConcurrent: 2, download: slowTicks)
        defer { try? fm.removeItem(at: rtT) }
        let tickRow = stT.model(for: attachment(0, .image, "/tmp/tick.png"), context: bctx)
        stT.fetch(tickRow, context: bctx, manual: false)
        _ = await waitUntil(3) { tap.count >= 1 }
        stT.cancelAutomatic(tickRow)
        stT.fetch(tickRow, context: bctx, manual: false)            // asked again: another fetch of the same row
        _ = await waitUntil(3) { tap.count >= 2 }
        tap.tick(1)?(300, 1000)                                     // a tick of the current one
        try? await Task.sleep(nanoseconds: 100_000_000)
        tap.tick(0)?(777, 1000)                                     // a tick of the first fetch arrives late
        try? await Task.sleep(nanoseconds: 150_000_000)
        checkTrue("36 a progress tick of an earlier fetch does not touch the row of the next one", tickRow.phase == .some(.fetching(received: 300, total: 1000)))
        stT.cancelAutomatic(tickRow)

        // ── Save: a click whose bytes arrive while the island is folded, and a save that fails ──
        final class PanelCalls: @unchecked Sendable { var names: [String] = []; var destination: URL? }
        let panel = PanelCalls()
        let saveFolder = tempBase()
        try? fm.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: saveFolder) }
        var shown = false
        let (stV, _, rtV) = fresh(download: clean, chatShown: { shown }, savePanel: { name in panel.names.append(name); return panel.destination })
        defer { try? fm.removeItem(at: rtV) }
        let doc = stV.model(for: attachment(5, .document, "/tmp/report.pdf"), context: bctx)
        stV.fetch(doc, context: bctx, manual: true, thenSave: true)
        _ = await waitUntil(5) { phaseIsReady(doc) != nil }
        try? await Task.sleep(nanoseconds: 150_000_000)
        checkTrue("37 a Save click whose bytes arrive while the island is folded shows ready, opens no panel and waits for the next click",
                  phaseIsReady(doc) != nil && panel.names.isEmpty)
        shown = true
        let doc2 = stV.model(for: attachment(6, .document, "/tmp/other.pdf"), context: bctx)
        panel.destination = saveFolder.appendingPathComponent("Other.bin")
        stV.fetch(doc2, context: bctx, manual: true, thenSave: true)
        _ = await waitUntil(5) { doc2.saved != nil }
        checkTrue("37b ...with the island open the panel is asked once and the file is saved", panel.names.count == 1 && doc2.saved != nil && !doc2.saveFailed)
        panel.destination = saveFolder                      // a folder: the save cannot happen
        stV.save(doc2)
        _ = await waitUntil(5) { doc2.saveFailed }
        checkTrue("37c a save that fails says so on the row (and the earlier copy is still where it was)",
                  doc2.saveFailed && fm.fileExists(atPath: saveFolder.appendingPathComponent("Other.bin").path))
        panel.destination = saveFolder.appendingPathComponent("Again.bin")
        stV.save(doc2)
        _ = await waitUntil(5) { !doc2.saveFailed }
        checkTrue("37d ...and a later save that works clears it", !doc2.saveFailed && doc2.saved?.lastPathComponent == "Again.bin")

        print(failures == 0 ? "\nAll ChatMediaStore tests passed." : "\n\(failures) ChatMediaStore test(s) FAILED.")
        exit(failures == 0 ? 0 : 1)
    }

    static func waitUntilAsync(_ timeout: Double, _ cond: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await cond() { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return await cond()
    }
}

extension FileManager {
    func subpathsOfDirectory(atPathOrNil path: String) -> [String]? { try? subpathsOfDirectory(atPath: path) }
}
