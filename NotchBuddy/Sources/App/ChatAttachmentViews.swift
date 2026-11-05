import SwiftUI
import AppKit

// The rows of the attachments of an answer (variant "Na carta"): drawn inside the answer card, where the directive
// line was. Voice and audio play on a click, an image shows inline, a document is saved on a click, a file that stayed on
// the machine of an API key agent says so (no button), a web address opens through the link rules.
// Colours and sizes are the tokens of the shipped card and chips (see design-media.md); the agent colour is only the
// position fill and the voice glyph. No waveform: the bar is only the position.

private enum MediaTokens {
    static let bright = Color(hex: "#F1F2F4")
    static let chipStrong = Color(hex: "#C5C8CD")
    static let chipText = Color(hex: "#9398A1")
    static let label = Color(hex: "#8E939C")
    static let dim = Color(hex: "#6B7079")
    static let inset = Color(hex: "#0D0E12")
    static let red = Color(hex: "#F4505E")
}

private func clock(_ seconds: Double) -> String {
    let n = max(0, Int(seconds.rounded()))
    return "\(n / 60):" + String(format: "%02d", n % 60)
}

private func kindSymbol(_ kind: ChatAttachmentKind) -> String {
    switch kind {
    case .voice: return "mic.fill"
    case .audio: return "speaker.wave.2.fill"
    case .image: return "photo"
    case .video: return "film"
    case .document: return "doc.text.fill"
    }
}

private func kindLabel(_ kind: ChatAttachmentKind) -> String {
    switch kind {
    case .voice: return String(localized: "Voice message")
    case .audio: return String(localized: "Audio")
    case .image: return String(localized: "Image")
    case .video: return String(localized: "Video")
    case .document: return String(localized: "Document")
    }
}

private func sizeText(_ bytes: Int) -> String { ChatMediaWords.size(bytes) }

// MARK: - Parts

private struct DiscView: View {
    var size: CGFloat = 34
    var symbol: String
    var fill: Color = Color.white.opacity(0.10)
    var glyph: Color = MediaTokens.bright
    var body: some View {
        ZStack {
            Circle().fill(fill)
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundColor(glyph)
                .offset(x: symbol == "play.fill" ? size * 0.03 : 0)
        }
        .frame(width: size, height: size)
    }
}

private struct PositionBar: View {
    var progress: Double
    var tint: Color
    var knob: Bool
    var body: some View {
        GeometryReader { g in
            let x = g.size.width * min(max(progress, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12)).frame(height: 4)
                if progress > 0 { Capsule().fill(tint).frame(width: max(4, x), height: 4) }
                if knob { Circle().fill(MediaTokens.bright).frame(width: 10, height: 10).offset(x: min(max(x - 5, 0), g.size.width - 10)) }
            }
            .frame(height: 10)
        }
        .frame(height: 10)
    }
}

private struct TimeLabel: View {
    var text: String
    var body: some View {
        Text(verbatim: text).font(.system(size: 11).monospacedDigit()).foregroundColor(MediaTokens.label).lineLimit(1).fixedSize()
    }
}

/// The small action capsule: the `ContextChip` family (white 0.10, capsule, 11.5).
private struct ActionCapsule: View {
    var symbol: String
    var title: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            Text(verbatim: title).font(.system(size: 11.5, weight: .medium))
        }
        .foregroundColor(MediaTokens.bright)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.white.opacity(0.10))
        .clipShape(Capsule())
        .fixedSize()
        .contentShape(Capsule())
    }
}

private struct FetchRing: View {
    var progress: Double?
    var color: Color
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.12), lineWidth: 2)
            Circle().trim(from: 0, to: progress ?? 0.12).stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
            Image(systemName: "arrow.down").font(.system(size: 34 * 0.34, weight: .semibold)).foregroundColor(MediaTokens.label)
        }
        .frame(width: 32, height: 32).frame(width: 34, height: 34)
    }
}

private struct UnavailableDisc: View {
    var symbol: String
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [2.5, 2.5]))
            Image(systemName: symbol).font(.system(size: 34 * 0.36)).foregroundColor(MediaTokens.dim)
        }
        .frame(width: 34, height: 34)
    }
}

/// Dark inset of the card family: the code block and table colour, radius 12 like the ask.
private struct Inset<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(.horizontal, 12).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MediaTokens.inset)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

/// The first line of a row: the glyph, the kind, the file name.
private struct TitleLine: View {
    var kind: ChatAttachmentKind
    var name: String
    var glyphTint: Color
    var dimmed = false
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: kindSymbol(kind)).font(.system(size: 10)).foregroundColor(glyphTint)
            Text(verbatim: kindLabel(kind)).font(.system(size: 12, weight: .medium)).foregroundColor(dimmed ? MediaTokens.label : MediaTokens.chipStrong)
            Text(verbatim: name).font(.system(size: 11.5)).foregroundColor(MediaTokens.dim).lineLimit(1).truncationMode(.middle)
        }
    }
}

// MARK: - Entry

/// The row of one attachment of an answer. Reads the context of the chat for where the answer came from.
struct ChatAttachmentRow: View {
    let attachment: ChatAttachment
    @Environment(\.chatMedia) private var context

    var body: some View {
        switch attachment.source {
        case .remote(let url):
            ChatRemoteRow(attachment: attachment, url: url, tint: Color(hex: context.colorHex))
        case .agentPath:
            if context.canFetch {
                ChatFetchedRow(model: ChatMediaStore.shared.model(for: attachment, context: context), attachment: attachment, context: context)
            } else {
                ChatUnavailableRow(attachment: attachment, agentName: context.agentName)
            }
        }
    }
}

// MARK: - An API key agent: the file stayed on the agent's machine

struct ChatUnavailableRow: View {
    let attachment: ChatAttachment
    let agentName: String

    var body: some View {
        Inset {
            HStack(alignment: .center, spacing: 12) {
                UnavailableDisc(symbol: kindSymbol(attachment.kind))
                VStack(alignment: .leading, spacing: 7) {
                    TitleLine(kind: attachment.kind, name: attachment.name, glyphTint: MediaTokens.chipText, dimmed: true)
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "desktopcomputer").font(.system(size: 10)).foregroundColor(MediaTokens.dim).padding(.top, 2)
                        Text(verbatim: location).font(.system(size: 11.5)).foregroundColor(MediaTokens.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var location: String { ChatMediaWords.unavailable(agentName: agentName) }
}

// MARK: - A web address: never fetched, a click goes through the link rules

struct ChatRemoteRow: View {
    let attachment: ChatAttachment
    let url: String
    let tint: Color

    private var shown: String { ChatMediaDirectives.shownRemote(url) }

    var body: some View {
        Inset {
            HStack(alignment: .center, spacing: 12) {
                DiscView(symbol: "link", fill: Color.white.opacity(0.06), glyph: MediaTokens.label)
                VStack(alignment: .leading, spacing: 7) {
                    TitleLine(kind: attachment.kind == .voice ? .audio : attachment.kind, name: attachment.name, glyphTint: MediaTokens.chipText)
                    Text(verbatim: shown).font(.system(size: 11.5)).foregroundColor(MediaTokens.label).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Button(action: open) { ActionCapsule(symbol: "arrow.up.right", title: String(localized: "Open")) }
                    .buttonStyle(.plain)
                    .help(String(localized: "Opens \(shown) in the browser"))
            }
        }
    }

    /// Always asks first: the row is the agent's own text, so nothing about it proves where the address goes. The dialog
    /// shows the real host.
    private func open() {
        guard let safe = safeWebURL(url) else { return }
        LinkConfirmation.ask(destination: safe, label: attachment.name)
    }
}

// MARK: - A file of a sign in agent

struct ChatFetchedRow: View {
    @ObservedObject var model: ChatMediaItemModel
    /// What the answer says about this file now (the kind can change while the text streams).
    let attachment: ChatAttachment
    let context: ChatMediaContext
    @ObservedObject private var visibility = ChatMediaVisibility.shared

    private var tint: Color { Color(hex: context.colorHex) }
    /// What the row is: the claim of the agent as it stands now, held down by what the bytes allow.
    private var kind: ChatAttachmentKind {
        if case .ready(let r) = model.phase { return ChatMediaStore.effectiveKind(claimed: attachment.kind, verified: r.kind) }
        return attachment.kind
    }

    private var fetchesByItself: Bool { ChatMediaFetch.autoCap(for: attachment.kind) != nil }

    var body: some View {
        Group {
            switch (kind, model.phase) {
            case (.image, .some(.ready(let ready))): imageReady(ready)
            case (.image, .none), (.image, .some(.fetching)): imageFetching
            case (.voice, _), (.audio, _): audioRow
            default: documentRow
            }
        }
        // Fetches by itself only while the chat is on screen; folded or hidden, nothing is asked.
        .task(id: visibility.shown) {
            guard visibility.shown, model.phase == nil, fetchesByItself else { return }
            ChatMediaStore.shared.fetch(model, context: context, manual: false)
        }
        // The row went away (the conversation was cleared, the chat closed): a fetch it started by itself ends.
        .onAppear { ChatMediaStore.shared.rowAppeared(model) }
        .onDisappear { ChatMediaStore.shared.rowDisappeared(model) }
    }

    // MARK: Voice and audio

    private var audioRow: some View {
        Inset {
            HStack(alignment: .center, spacing: 12) {
                audioLeading
                VStack(alignment: .leading, spacing: 7) {
                    TitleLine(kind: kind, name: attachment.name,
                              glyphTint: kind == .voice ? tint : MediaTokens.chipText)
                    audioDetail
                }
                Spacer(minLength: 8)
                trailing
            }
        }
    }

    @ViewBuilder private var audioLeading: some View {
        switch model.phase {
        case .some(.ready):
            Button { ChatMediaStore.shared.togglePlay(model) } label: {
                DiscView(symbol: model.playing ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Play / Pause"))
        case .some(.fetching(let received, let total)):
            FetchRing(progress: fraction(received, total), color: tint)
        case .some(.needsClick), .some(.overBudget):
            DiscView(symbol: "arrow.down", fill: Color.white.opacity(0.06), glyph: MediaTokens.label)
        case .some(.failed):
            DiscView(symbol: "exclamationmark", fill: MediaTokens.red.opacity(0.14), glyph: MediaTokens.red)
        case .none:
            FetchRing(progress: nil, color: tint)
        }
    }

    @ViewBuilder private var audioDetail: some View {
        switch model.phase {
        case .some(.ready(let ready)):
            let duration = ready.duration ?? 0
            // No tick at all while paused, finished or off screen: the bar reads the player only while it plays.
            TimelineView(.animation(minimumInterval: 0.1, paused: !model.playing)) { _ in
                let at = min(model.position(), duration)
                HStack(spacing: 10) {
                    PositionBar(progress: duration > 0 ? at / duration : 0, tint: tint, knob: model.playing)
                    TimeLabel(text: model.playing || at > 0 ? "\(clock(at)) / \(clock(duration))" : clock(duration))
                }
            }
        case .some(.fetching(let received, let total)):
            HStack(spacing: 10) {
                PositionBar(progress: fraction(received, total) ?? 0, tint: MediaTokens.chipText, knob: false)
                TimeLabel(text: percentText(received, total))
            }
        case .some(.needsClick(let bytes)):
            Text(verbatim: tooLargeText(bytes)).font(.system(size: 11.5)).foregroundColor(MediaTokens.label)
        case .some(.overBudget):
            Text(verbatim: ChatMediaWords.overBudget()).font(.system(size: 11.5)).foregroundColor(MediaTokens.label)
                .fixedSize(horizontal: false, vertical: true)
        case .some(.failed(let failure)):
            Text(verbatim: failureText(failure)).font(.system(size: 11.5)).foregroundColor(MediaTokens.red.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        case .none:
            HStack(spacing: 10) {
                PositionBar(progress: 0, tint: MediaTokens.chipText, knob: false)
                TimeLabel(text: String(localized: "Fetching…"))
            }
        }
    }

    // MARK: Image

    private var imageFetching: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05))
                VStack(spacing: 8) {
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.12), lineWidth: 2)
                        Circle().trim(from: 0, to: imageFraction ?? 0.12).stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                        Image(systemName: "arrow.down").font(.system(size: 10, weight: .semibold)).foregroundColor(MediaTokens.label)
                    }.frame(width: 28, height: 28)
                    Text(verbatim: imagePercent).font(.system(size: 11)).foregroundColor(MediaTokens.label)
                }
            }
            .frame(width: 300, height: 176)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
            caption(pixels: nil)
        }
    }

    private var imageFraction: Double? {
        if case .some(.fetching(let r, let t)) = model.phase { return fraction(r, t) }
        return nil
    }

    private var imagePercent: String {
        if case .some(.fetching(let r, let t)) = model.phase { return percentText(r, t) }
        return String(localized: "Fetching…")
    }

    @ViewBuilder private func imageReady(_ ready: ChatMediaItemModel.Ready) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if let image = model.thumbnail {
                Button { ChatMediaStore.shared.open(model) } label: {
                    Image(nsImage: image)
                        .resizable().scaledToFit()
                        .frame(maxWidth: 300, maxHeight: 176)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 9.5, weight: .semibold)).foregroundColor(MediaTokens.bright)
                                .frame(width: 24, height: 24).background(Color.black.opacity(0.45)).clipShape(Circle()).padding(8)
                        }
                }
                .buttonStyle(.plain)
                .help(String(localized: "Open"))
                .accessibilityLabel(Text(verbatim: attachment.name))
            }
            caption(pixels: ready.pixels)
        }
    }

    private func caption(pixels: CGSize?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "photo").font(.system(size: 10)).foregroundColor(MediaTokens.chipText)
            Text("Image").font(.system(size: 12, weight: .medium)).foregroundColor(MediaTokens.chipStrong)
            Text(verbatim: pixels.map { "\(attachment.name) · \(Int($0.width))×\(Int($0.height))" } ?? attachment.name)
                .font(.system(size: 11.5)).foregroundColor(MediaTokens.dim).lineLimit(1).truncationMode(.middle)
        }
    }

    // MARK: Document and video

    private var documentRow: some View {
        Inset {
            HStack(spacing: 12) {
                documentLeading
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: attachment.name).font(.system(size: 12.5, weight: .medium)).foregroundColor(MediaTokens.bright)
                        .lineLimit(1).truncationMode(.middle)
                    documentDetail
                }
                Spacer(minLength: 8)
                trailing
            }
        }
    }

    @ViewBuilder private var documentLeading: some View {
        switch model.phase {
        case .some(.fetching(let received, let total)): FetchRing(progress: fraction(received, total), color: tint)
        case .some(.failed): DiscView(symbol: "exclamationmark", fill: MediaTokens.red.opacity(0.14), glyph: MediaTokens.red)
        case .some(.needsClick), .some(.overBudget): DiscView(symbol: "arrow.down", fill: Color.white.opacity(0.06), glyph: MediaTokens.label)
        default:
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.07))
                Image(systemName: kind == .video ? "film" : "doc.text.fill").font(.system(size: 15)).foregroundColor(MediaTokens.chipText)
            }
            .frame(width: 34, height: 34)
        }
    }

    @ViewBuilder private var documentDetail: some View {
        switch model.phase {
        case .some(.fetching(let received, let total)):
            Text(verbatim: percentText(received, total)).font(.system(size: 11.5)).foregroundColor(MediaTokens.dim)
        case .some(.failed(let failure)):
            Text(verbatim: failureText(failure)).font(.system(size: 11.5)).foregroundColor(MediaTokens.red.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        case .some(.needsClick(let bytes)):
            Text(verbatim: tooLargeText(bytes)).font(.system(size: 11.5)).foregroundColor(MediaTokens.label)
        case .some(.overBudget):
            Text(verbatim: ChatMediaWords.overBudget()).font(.system(size: 11.5)).foregroundColor(MediaTokens.label)
                .fixedSize(horizontal: false, vertical: true)
        default:
            if model.saveFailed {
                Text(verbatim: ChatMediaWords.saveFailed()).font(.system(size: 11.5)).foregroundColor(MediaTokens.red.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(verbatim: documentSubtitle).font(.system(size: 11.5)).foregroundColor(MediaTokens.dim).lineLimit(1)
            }
        }
    }

    /// "Document · PDF · 248 KB". The extension is the one the saved file will have (what the bytes are), so the row never
    /// hides what a file really is behind the agent's name.
    private var documentSubtitle: String {
        var parts = [kind == .video ? String(localized: "Video") : String(localized: "Document")]
        if case .some(.ready(let ready)) = model.phase {
            parts.append(ChatMediaStore.finalExtension(attachment.name, format: ready.format, text: ready.text).uppercased())
            parts.append(sizeText(ready.bytes))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Buttons

    @ViewBuilder private var trailing: some View {
        switch model.phase {
        case .some(.ready):
            if kind == .document || kind == .video {
                HStack(spacing: 6) {
                    if let saved = model.saved {
                        Button { ChatMediaStore.shared.showInFinder(saved) } label: { ActionCapsule(symbol: "folder", title: String(localized: "Show in Finder")) }
                            .buttonStyle(.plain)
                    }
                    Button { ChatMediaStore.shared.save(model) } label: { ActionCapsule(symbol: "arrow.down.to.line", title: String(localized: "Save…")) }
                        .buttonStyle(.plain)
                }
            }
        case .some(.needsClick), .some(.overBudget):
            Button { ChatMediaStore.shared.fetch(model, context: context, manual: true) } label: { ActionCapsule(symbol: "arrow.down", title: String(localized: "Download")) }
                .buttonStyle(.plain)
        case .some(.failed(let failure)):
            if canRetry(failure) {
                Button { ChatMediaStore.shared.retry(model, context: context) } label: { ActionCapsule(symbol: "arrow.clockwise", title: String(localized: "Try again")) }
                    .buttonStyle(.plain)
            }
        case .none:
            if !fetchesByItself {
                Button { ChatMediaStore.shared.fetch(model, context: context, manual: true, thenSave: true) } label: {
                    ActionCapsule(symbol: "arrow.down.to.line", title: String(localized: "Save…"))
                }
                .buttonStyle(.plain)
            }
        case .some(.fetching):
            EmptyView()
        }
    }

    private func canRetry(_ failure: ChatMediaFetch.Failure) -> Bool {
        switch failure {
        case .tooLarge, .refused, .notAvailable: return false
        default: return true
        }
    }

    // MARK: Words

    private func fraction(_ received: Int, _ total: Int?) -> Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(received) / Double(total))
    }

    private func percentText(_ received: Int, _ total: Int?) -> String {
        ChatMediaWords.fetching(fraction: fraction(received, total))
    }

    private func tooLargeText(_ bytes: Int?) -> String { ChatMediaWords.tooLarge(bytes: bytes) }

    private func failureText(_ failure: ChatMediaFetch.Failure) -> String {
        switch failure {
        case .notFound: return String(localized: "File not found on the server.")
        case .refused, .notAvailable: return String(localized: "The server refused this file.")
        case .tooLarge(let bytes): return tooLargeText(bytes)
        case .network, .signIn, .unreadable: return String(localized: "Could not fetch the file.")
        case .cannotPlay: return String(localized: "Could not play the file.")
        }
    }
}
