#if !APPSTORE
import AppKit
import Carbon.HIToolbox
import SwiftUI

/// ⌘⇧S: capture a part of the screen (a bug in a page, an error, a mock-up), Mochi swallows it,
/// and the island offers what to do with it: paste it into the prompt you were typing in, copy
/// it, annotate it, or ask Claude about it in the island's chat.
///
/// With Flow: keep the capture on the island and hold the dictation key: "this button is off,
/// fix it". When you let go, the image and your words are pasted together where you type.
///
/// The selection is macOS's own (screencapture -i): drag a zone, Space for a window, Esc to
/// cancel. The image stays on the Mac (in the temporary folder); it only goes to Claude when you
/// paste it there or ask Claude about it.
@MainActor
final class ScreenCapture: ObservableObject {
    static let shared = ScreenCapture()

    /// The capture on the island, if any.
    @Published private(set) var url: URL? = nil
    @Published private(set) var image: NSImage? = nil
    /// The app in front when the capture was taken: the image goes back there.
    private(set) var target: NSRunningApplication? = nil
    private var takenAt: Date? = nil
    private var running = false
    private var annotation: NSWindow? = nil

    private static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CoucouCaptures", isDirectory: true)
    }

    private init() {}

    // MARK: - Capturing

    func begin() {
        guard !running else {
            appendAppLog("nb.log", "[Capture] already selecting a zone")
            return
        }
        SoundEngine.shared.play("tick")
        guard CGPreflightScreenCaptureAccess() else {
            appendAppLog("nb.log", "[Capture] no Screen Recording permission: asking")
            // macOS asks once; then Coucou is to be allowed in Privacy → Screen Recording.
            _ = CGRequestScreenCaptureAccess()
            AppState.shared.noteMessage = String(localized: "capture.permission")
            NotificationCenter.default.post(name: .hookExpand, object: IslandView.note)
            return
        }
        let ours = Bundle.main.bundleIdentifier
        let front = NSWorkspace.shared.frontmostApplication
        target = front?.bundleIdentifier == ours ? AppState.shared.lastExternalApp : front
        // The island folds first: it must not be in the picture.
        if AppState.shared.mode == .expanded {
            NotificationCenter.default.post(name: .islandCollapse, object: nil)
        }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stamp = formatter.string(from: Date())
        let file = Self.folder.appendingPathComponent("Capture \(stamp).png")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i: macOS's own selection; -x: no shutter sound (Mochi makes his own); -o: no window shadow.
        task.arguments = ["-i", "-x", "-o", file.path]
        task.terminationHandler = { _ in
            Task { @MainActor in ScreenCapture.shared.finished(file) }
        }
        do {
            running = true
            try task.run()
            appendAppLog("nb.log", "[Capture] selection started")
        } catch {
            running = false
            appendAppLog("nb.log", "[Capture] screencapture failed: \(error)")
        }
    }

    private func finished(_ file: URL) {
        running = false
        appendAppLog("nb.log", "[Capture] selection ended, image: \(FileManager.default.fileExists(atPath: file.path) ? "yes" : "no (cancelled)")")
        // Esc: no file, nothing happens.
        guard FileManager.default.fileExists(atPath: file.path), let picture = NSImage(contentsOf: file) else { return }
        show(file, picture)
        prune()
    }

    /// The capture lands on the island: Mochi swallows it.
    private func show(_ file: URL, _ picture: NSImage) {
        url = file
        image = picture
        takenAt = Date()
        SoundEngine.shared.play("gulp")
        NotificationCenter.default.post(name: .hookExpand, object: IslandView.capture)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            NotificationCenter.default.post(name: .botGulp, object: nil)
        }
    }

    /// Done with it: the card closes.
    func dismiss() {
        url = nil
        image = nil
        takenAt = nil
        if AppState.shared.view == .capture {
            NotificationCenter.default.post(name: .islandCollapse, object: nil)
        }
    }

    /// Keeps the last 20 captures.
    private func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a > b
        }
        for old in sorted.dropFirst(20) where old != url { try? fm.removeItem(at: old) }
    }

    // MARK: - The island's buttons

    /// Into the prompt of the app you were in (⌘V, or ⌃V in a terminal, where Claude Code takes images).
    func pasteIntoPrompt() {
        guard let file = url, let data = try? Data(contentsOf: file) else { return }
        let app = target
        NotificationCenter.default.post(name: .islandCollapse, object: nil)
        Task { @MainActor in
            _ = app?.activate()
            try? await Task.sleep(for: .milliseconds(250))
            if CapturePaste.paste(png: data, image: image, into: app) {
                SoundEngine.shared.play("send")
            } else {
                AppState.shared.noteMessage = String(localized: "capture.copied")
                NotificationCenter.default.post(name: .hookExpand, object: IslandView.note)
            }
            dismiss()
        }
    }

    func copy() {
        guard let file = url, let data = try? Data(contentsOf: file) else { return }
        CapturePaste.put(png: data, image: image, transient: false)
        SoundEngine.shared.play("pop")
        dismiss()
    }

    /// The island's chat, with the capture attached.
    func askClaude() {
        guard let file = url else { return }
        let name = String(localized: "capture.name")
        AppState.shared.droppedFile = DroppedFile(url: file, name: name)
        AppState.shared.promptContext = .file(name: name, fileURL: file)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            AppState.shared.view = .prompt
        }
    }

    // MARK: - With Flow

    /// A capture on the island, fresh and not used yet: the next dictation takes it with its words.
    var waitingForDictation: Bool {
        guard url != nil, let at = takenAt, Date().timeIntervalSince(at) < 180 else { return false }
        return AppState.shared.mode == .expanded && AppState.shared.view == .capture
    }

    /// Pastes the capture where you type, before the words of the dictation. True when pasted.
    func pasteForDictation() async -> Bool {
        guard waitingForDictation, let file = url, let data = try? Data(contentsOf: file) else { return false }
        let front = NSWorkspace.shared.frontmostApplication
        let pasted = CapturePaste.paste(png: data, image: image, into: front, restore: false)
        dismiss()
        // The app reads the image before the words arrive.
        try? await Task.sleep(for: .milliseconds(450))
        return pasted
    }

    // MARK: - Annotating

    func annotate() {
        guard let picture = image else { return }
        annotation?.close()
        let view = CaptureAnnotationView(image: picture) { [weak self] result in
            self?.finishAnnotation(result)
        }
        let maxW: CGFloat = 1100, maxH: CGFloat = 720
        let size = picture.size
        let scale = min(1, min(maxW / max(1, size.width), maxH / max(1, size.height)))
        let content = NSSize(width: max(420, size.width * scale), height: size.height * scale + 56)
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: content),
                           styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        win.title = String(localized: "capture.annotate")
        win.titlebarAppearsTransparent = true
        win.appearance = NSAppearance(named: .darkAqua)
        win.backgroundColor = .black
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: view)
        win.level = .floating
        win.center()
        annotation = win
        NotificationCenter.default.post(name: .islandCollapse, object: nil)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    private func finishAnnotation(_ result: NSImage?) {
        annotation?.close()
        annotation = nil
        guard let result, let png = CapturePaste.pngData(result) else {
            if url != nil { NotificationCenter.default.post(name: .hookExpand, object: IslandView.capture) }
            return
        }
        let file = Self.folder.appendingPathComponent((url?.deletingPathExtension().lastPathComponent ?? "Capture") + " annotated.png")
        do {
            try png.write(to: file, options: .atomic)
        } catch {
            appendAppLog("nb.log", "[Capture] annotated image not saved: \(error)")
            return
        }
        _ = target?.activate()
        show(file, result)
    }
}

// MARK: - Pasting an image

enum CapturePaste {
    /// The terminals where Claude Code takes an image with ⌃V.
    static func isTerminal(_ app: NSRunningApplication?) -> Bool {
        guard let id = app?.bundleIdentifier else { return false }
        return TerminalTarget.knownTerminals.contains(id)
    }

    @MainActor static func put(png: Data, image: NSImage?, transient: Bool) {
        let board = NSPasteboard.general
        board.clearContents()
        var types: [NSPasteboard.PasteboardType] = [.png]
        let tiff = image?.tiffRepresentation
        if tiff != nil { types.append(.tiff) }
        if transient { types += [FlowPaste.transientType, FlowPaste.autoGeneratedType] }
        board.declareTypes(types, owner: nil)
        board.setData(png, forType: .png)
        if let tiff { board.setData(tiff, forType: .tiff) }
        if transient {
            board.setData(Data(), forType: FlowPaste.transientType)
            board.setData(Data(), forType: FlowPaste.autoGeneratedType)
        }
    }

    /// Puts the image on the clipboard and sends the paste keys to the app in front. False without
    /// the Accessibility permission (the image then stays on the clipboard).
    @MainActor static func paste(png: Data, image: NSImage?, into app: NSRunningApplication?, restore: Bool = true) -> Bool {
        let board = NSPasteboard.general
        let saved = restore ? snapshot(board) : []
        put(png: png, image: image, transient: true)
        guard AXIsProcessTrusted() else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        let terminal = isTerminal(app)
        let key = terminal ? CGKeyCode(kVK_ANSI_V) : FlowPaste.vKeyCode()
        let flags: CGEventFlags = terminal ? .maskControl : .maskCommand
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        guard restore else { return true }
        // Claude Code in a terminal reads the clipboard itself, a little later: give it time,
        // then put back what was there, unless something else was copied meanwhile.
        let count = board.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            guard board.changeCount == count else { return }
            board.clearContents()
            guard !saved.isEmpty else { return }
            board.writeObjects(saved.map { entry in
                let item = NSPasteboardItem()
                for (type, data) in entry { item.setData(data, forType: type) }
                return item
            })
        }
        return true
    }

    @MainActor private static func snapshot(_ board: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (board.pasteboardItems ?? []).map { item in
            var out: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { out[type] = data } }
            return out
        }
    }

    static func pngData(_ image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}

// MARK: - Annotation window

/// Arrows, boxes and a pen over the capture, then Done.
struct CaptureAnnotationView: View {
    let image: NSImage
    let onDone: @MainActor (NSImage?) -> Void

    enum Tool: CaseIterable { case arrow, box, pen }

    struct Mark {
        var tool: Tool
        var color: Int
        /// In the image's own proportions: (0, 0) top left, (1, 1) bottom right.
        var points: [CGPoint]
    }

    static let colors: [NSColor] = [
        NSColor(red: 1, green: 0.27, blue: 0.23, alpha: 1),
        NSColor(red: 1, green: 0.8, blue: 0.0, alpha: 1),
        NSColor(red: 0.23, green: 0.62, blue: 1, alpha: 1),
        NSColor.white,
    ]

    @State private var marks: [Mark] = []
    @State private var drawing: Mark? = nil
    @State private var tool: Tool = .arrow
    @State private var color = 0

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            GeometryReader { geo in
                let fit = Self.fitted(image.size, in: geo.size)
                ZStack(alignment: .topLeading) {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: fit.width, height: fit.height)
                    Canvas { ctx, size in
                        for mark in marks + (drawing.map { [$0] } ?? []) {
                            Self.draw(mark, in: &ctx, size: size, lineWidth: 3)
                        }
                    }
                    .frame(width: fit.width, height: fit.height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let p = CGPoint(x: min(1, max(0, g.location.x / fit.width)),
                                            y: min(1, max(0, g.location.y / fit.height)))
                            if drawing == nil {
                                drawing = Mark(tool: tool, color: color, points: [p, p])
                            } else if tool == .pen {
                                drawing?.points.append(p)
                            } else {
                                drawing?.points[1] = p
                            }
                        }
                        .onEnded { _ in
                            if let mark = drawing { marks.append(mark) }
                            drawing = nil
                        })
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            ForEach(Array(Tool.allCases.enumerated()), id: \.offset) { _, t in
                Button { tool = t } label: {
                    Image(systemName: t == .arrow ? "arrow.up.right" : (t == .box ? "rectangle" : "pencil.tip"))
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(tool == t ? 0.16 : 0.05)))
                }
                .buttonStyle(.plain)
            }
            Divider().frame(height: 18)
            ForEach(0..<Self.colors.count, id: \.self) { i in
                Button { color = i } label: {
                    Circle()
                        .fill(Color(nsColor: Self.colors[i]))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().stroke(Color.white.opacity(color == i ? 0.9 : 0), lineWidth: 2).padding(-3))
                }
                .buttonStyle(.plain)
            }
            Divider().frame(height: 18)
            Button { if !marks.isEmpty { marks.removeLast() } } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 26)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("z", modifiers: .command)
            .disabled(marks.isEmpty)
            Spacer()
            Button(String(localized: "Cancel")) { onDone(nil) }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "capture.done")) { onDone(render()) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: "#FB923C"))
        }
        .foregroundColor(Color(hex: "#F5F6F8"))
        .padding(.leading, 82)      // clear of the window's buttons
        .padding(.trailing, 14)
        .frame(height: 56)
    }

    static func fitted(_ image: CGSize, in box: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return box }
        let s = min(box.width / image.width, box.height / image.height)
        return CGSize(width: image.width * s, height: image.height * s)
    }

    /// One mark, in a canvas of `size` (y down).
    static func draw(_ mark: Mark, in ctx: inout GraphicsContext, size: CGSize, lineWidth: CGFloat) {
        let pts = mark.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        guard let first = pts.first, let last = pts.last else { return }
        let shading = GraphicsContext.Shading.color(Color(nsColor: colors[mark.color]))
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        switch mark.tool {
        case .pen:
            var p = Path()
            p.addLines(pts)
            ctx.stroke(p, with: shading, style: style)
        case .box:
            let rect = CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                              width: abs(last.x - first.x), height: abs(last.y - first.y))
            ctx.stroke(Path(roundedRect: rect, cornerRadius: lineWidth * 1.5), with: shading, style: style)
        case .arrow:
            ctx.stroke(arrow(from: first, to: last, head: lineWidth * 5), with: shading, style: style)
        }
    }

    static func arrow(from a: CGPoint, to b: CGPoint, head: CGFloat) -> Path {
        var p = Path()
        p.move(to: a)
        p.addLine(to: b)
        let angle = atan2(b.y - a.y, b.x - a.x)
        guard hypot(b.x - a.x, b.y - a.y) > head * 0.5 else { return p }
        for side in [-1.0, 1.0] as [CGFloat] {
            let wing = angle + .pi + side * .pi / 7
            p.move(to: b)
            p.addLine(to: CGPoint(x: b.x + cos(wing) * head, y: b.y + sin(wing) * head))
        }
        return p
    }

    /// The capture with its marks, at the capture's full size.
    @MainActor private func render() -> NSImage? {
        guard !marks.isEmpty else { return image }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let size = CGSize(width: cg.width, height: cg.height)
        let marks = self.marks
        let view = Canvas { ctx, s in
            ctx.draw(Image(decorative: cg, scale: 1), in: CGRect(origin: .zero, size: s))
            for mark in marks {
                Self.draw(mark, in: &ctx, size: s, lineWidth: max(3, s.width / 300))
            }
        }
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let out = renderer.cgImage else { return nil }
        return NSImage(cgImage: out, size: image.size)
    }
}
#endif
