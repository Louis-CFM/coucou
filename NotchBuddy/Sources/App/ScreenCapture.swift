#if !APPSTORE
import AppKit
import Carbon.HIToolbox
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UniformTypeIdentifiers

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
        let view = CaptureAnnotationView(image: picture, onDone: { [weak self] result in
            self?.finishAnnotation(result)
        }, onSave: { [weak self] result in
            self?.saveAnnotation(result)
        })
        let maxW: CGFloat = 1100, maxH: CGFloat = 720
        let size = picture.size
        let scale = min(1, min(maxW / max(1, size.width), maxH / max(1, size.height)))
        // 780 pt at least: the toolbar's seven tools, colours, undo and three buttons.
        let content = NSSize(width: max(780, size.width * scale), height: size.height * scale + 56)
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

    // MARK: - Saving

    /// The folder of the last save; the Desktop the first time, like macOS's own screenshots.
    private static let saveFolderKey = "captureSaveFolder"

    /// A click on the island's thumbnail: a PNG, named like the file in the temporary folder
    /// ("Capture 2026-10-15 at 19.57.03.png"), in the folder you choose.
    func save() {
        guard let file = url, let data = try? Data(contentsOf: file) else { return }
        Self.save(png: data, suggestedName: file.lastPathComponent, in: nil) { [weak self] saved in
            guard let self else { return }
            if saved {
                SoundEngine.shared.play("pop")
                dismiss()
            } else if url != nil {
                // Cancelled: the capture stays on the island.
                NotificationCenter.default.post(name: .hookExpand, object: IslandView.capture)
            }
        }
    }

    /// Save in the annotation window: the marks burnt in, the file where you choose, then the
    /// annotated capture comes back to the island.
    private func saveAnnotation(_ result: NSImage) {
        guard let png = CapturePaste.pngData(result) else { return }
        let name = (url?.deletingPathExtension().lastPathComponent ?? "Capture") + " annotated.png"
        Self.save(png: png, suggestedName: name, in: annotation) { [weak self] saved in
            guard saved else { return }
            SoundEngine.shared.play("pop")
            self?.finishAnnotation(result)
        }
    }

    /// The system's save panel: a sheet of `window` when there is one, a window of its own otherwise
    /// (the island cannot hold a sheet). `done(true)` once the file is written.
    private static func save(png: Data, suggestedName: String, in window: NSWindow?,
                             done: @escaping @MainActor @Sendable (Bool) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        panel.directoryURL = UserDefaults.standard.url(forKey: saveFolderKey)
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        let handler: @MainActor @Sendable (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let target = panel.url else { done(false); return }
            do {
                try png.write(to: target, options: .atomic)
                UserDefaults.standard.set(target.deletingLastPathComponent(), forKey: saveFolderKey)
                appendAppLog("nb.log", "[Capture] saved as a file")
                done(true)
            } catch {
                appendAppLog("nb.log", "[Capture] not saved: \(error)")
                AppState.shared.noteMessage = error.localizedDescription
                NotificationCenter.default.post(name: .hookExpand, object: IslandView.note)
                done(false)
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            NotificationCenter.default.post(name: .islandCollapse, object: nil)
            NSApp.activate()
            panel.begin(completionHandler: handler)
        }
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

/// Arrows, boxes, a pen, a line, a marker, an obscured zone and a word or two over the capture, then
/// Done (back to the island) or Save (a PNG where you choose).
struct CaptureAnnotationView: View {
    let image: NSImage
    let onDone: @MainActor (NSImage?) -> Void
    let onSave: @MainActor (NSImage) -> Void

    enum Tool: CaseIterable {
        case arrow, box, pen, line, marker, obscure, text

        var symbol: String {
            switch self {
            case .arrow: "arrow.up.right"
            case .box: "rectangle"
            case .pen: "pencil.tip"
            case .line: "line.diagonal"
            case .marker: "highlighter"
            case .obscure: "checkerboard.rectangle"
            case .text: "textformat"
            }
        }

        /// The tooltip.
        var name: String {
            switch self {
            case .arrow: String(localized: "capture.tool.arrow")
            case .box: String(localized: "capture.tool.box")
            case .pen: String(localized: "capture.tool.pen")
            case .line: String(localized: "capture.tool.line")
            case .marker: String(localized: "capture.tool.marker")
            case .obscure: String(localized: "capture.tool.obscure")
            case .text: String(localized: "capture.tool.text")
            }
        }
    }

    struct Mark {
        var tool: Tool
        var color: Int
        /// In the image's own proportions: (0, 0) top left, (1, 1) bottom right.
        var points: [CGPoint]
        /// The text tool's words, at the first point.
        var text: String = ""
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
    /// The words being typed where the text tool was clicked, in the image's proportions.
    @State private var draft: (point: CGPoint, text: String)? = nil
    @FocusState private var typing: Bool
    /// The capture in coarse blocks, made the first time the obscure tool is picked.
    @State private var mosaic: CGImage? = nil

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
                            Self.draw(mark, in: &ctx, size: size, lineWidth: 3, mosaic: mosaic)
                        }
                    }
                    .frame(width: fit.width, height: fit.height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            guard tool != .text else { return }   // the text tool acts when the click ends
                            let p = Self.proportional(g.location, in: fit)
                            if drawing == nil {
                                commitText()
                                drawing = Mark(tool: tool, color: color, points: [p, p])
                            } else if tool == .pen || tool == .marker {
                                drawing?.points.append(p)
                            } else {
                                drawing?.points[1] = p
                            }
                        }
                        .onEnded { g in
                            if tool == .text {
                                // A click starts a label there; the one being typed is kept.
                                commitText()
                                draft = (Self.proportional(g.location, in: fit), "")
                                return
                            }
                            if let mark = drawing { marks.append(mark) }
                            drawing = nil
                        })
                    if let draft { textField(draft, fit: fit) }
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
                Button { pick(t) } label: {
                    Image(systemName: t.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(tool == t ? 0.16 : 0.05)))
                }
                .buttonStyle(.plain)
                .help(t.name)
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
            Button { undo() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 26)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("z", modifiers: .command)
            .disabled(marks.isEmpty && draft == nil)
            Spacer()
            // Return and Esc belong to the label while one is being typed.
            if draft == nil {
                Button(String(localized: "Cancel")) { onDone(nil) }
                    .keyboardShortcut(.cancelAction)
            } else {
                Button(String(localized: "Cancel")) { onDone(nil) }
            }
            Button(String(localized: "capture.save")) { if let out = finished() { onSave(out) } }
                .keyboardShortcut("s", modifiers: .command)
            if draft == nil {
                doneButton.keyboardShortcut(.defaultAction)
            } else {
                doneButton
            }
        }
        .foregroundColor(Color(hex: "#F5F6F8"))
        .padding(.leading, 82)      // clear of the window's buttons
        .padding(.trailing, 14)
        .frame(height: 56)
    }

    private var doneButton: some View {
        Button(String(localized: "capture.done")) { onDone(finished()) }
            .buttonStyle(.borderedProminent)
            .tint(Color(hex: "#FB923C"))
    }

    /// The label being typed, over the picture: Return keeps it, Esc drops it.
    private func textField(_ draft: (point: CGPoint, text: String), fit: CGSize) -> some View {
        let at = CGPoint(x: draft.point.x * fit.width, y: draft.point.y * fit.height)
        return TextField("", text: Binding(get: { self.draft?.text ?? "" }, set: { self.draft?.text = $0 }))
            .textFieldStyle(.plain)
            .font(.system(size: Self.textSize(lineWidth: 3), weight: .semibold))
            .foregroundColor(Color(nsColor: Self.colors[color]))
            .focused($typing)
            .onSubmit { commitText() }
            .onExitCommand { self.draft = nil }
            .frame(width: max(120, fit.width - at.x - 4), alignment: .leading)
            .overlay(Rectangle().stroke(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .fixedSize(horizontal: false, vertical: true)
            .offset(x: at.x, y: at.y - 2)
            .onAppear { typing = true }
    }

    private func pick(_ t: Tool) {
        commitText()
        tool = t
        if t == .obscure, mosaic == nil { mosaic = Self.mosaic(of: image) }
    }

    /// The label being typed if there is one, else the last mark.
    private func undo() {
        if draft != nil { draft = nil; return }
        if !marks.isEmpty { marks.removeLast() }
    }

    /// The label being typed becomes a mark; nothing if it is empty.
    private func commitText() {
        guard let draft else { return }
        self.draft = nil
        let words = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        marks.append(Mark(tool: .text, color: color, points: [draft.point], text: words))
    }

    /// The capture with its marks, the label being typed included.
    @MainActor private func finished() -> NSImage? {
        commitText()
        return render()
    }

    static func fitted(_ image: CGSize, in box: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return box }
        let s = min(box.width / image.width, box.height / image.height)
        return CGSize(width: image.width * s, height: image.height * s)
    }

    /// A point of the window, in the image's proportions.
    static func proportional(_ p: CGPoint, in fit: CGSize) -> CGPoint {
        CGPoint(x: min(1, max(0, p.x / fit.width)), y: min(1, max(0, p.y / fit.height)))
    }

    /// The text's size follows the line width: 19.5 pt in the window, scaled like the strokes in the file.
    static func textSize(lineWidth: CGFloat) -> CGFloat { lineWidth * 6.5 }

    /// The capture in blocks of a hundredth of its width (12 pixels at least): unreadable, where a
    /// light blur can leave text legible.
    static func mosaic(of image: NSImage) -> CGImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cg)
        let filter = CIFilter.pixellate()
        filter.inputImage = input.clampedToExtent()
        filter.scale = Float(max(12, (CGFloat(cg.width) / 100).rounded()))
        filter.center = .zero
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return CIContext().createCGImage(output, from: input.extent)
    }

    /// One mark, in a canvas of `size` (y down). `lineWidth` sets the other measures: the marker is
    /// five times wider, the text six and a half times taller.
    static func draw(_ mark: Mark, in ctx: inout GraphicsContext, size: CGSize, lineWidth: CGFloat, mosaic: CGImage?) {
        let pts = mark.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        guard let first = pts.first, let last = pts.last else { return }
        let tint = Color(nsColor: colors[mark.color])
        let shading = GraphicsContext.Shading.color(tint)
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        switch mark.tool {
        case .pen:
            var p = Path()
            p.addLines(pts)
            ctx.stroke(p, with: shading, style: style)
        case .marker:
            var p = Path()
            p.addLines(pts)
            ctx.stroke(p, with: .color(tint.opacity(0.38)),
                       style: StrokeStyle(lineWidth: lineWidth * 5, lineCap: .round, lineJoin: .round))
        case .line:
            var p = Path()
            p.move(to: first)
            p.addLine(to: last)
            ctx.stroke(p, with: shading, style: style)
        case .box:
            let rect = CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                              width: abs(last.x - first.x), height: abs(last.y - first.y))
            ctx.stroke(Path(roundedRect: rect, cornerRadius: lineWidth * 1.5), with: shading, style: style)
        case .arrow:
            ctx.stroke(arrow(from: first, to: last, head: lineWidth * 5), with: shading, style: style)
        case .obscure:
            // The blocks show through the dragged rectangle.
            guard let mosaic else { return }
            let rect = CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                              width: abs(last.x - first.x), height: abs(last.y - first.y))
            var clipped = ctx
            clipped.clip(to: Path(rect))
            clipped.draw(Image(decorative: mosaic, scale: 1), in: CGRect(origin: .zero, size: size))
        case .text:
            let label = Text(mark.text)
                .font(.system(size: textSize(lineWidth: lineWidth), weight: .semibold))
                .foregroundColor(tint)
            ctx.draw(label, at: first, anchor: .topLeading)
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
        let mosaic = self.mosaic
        let view = Canvas { ctx, s in
            ctx.draw(Image(decorative: cg, scale: 1), in: CGRect(origin: .zero, size: s))
            for mark in marks {
                Self.draw(mark, in: &ctx, size: s, lineWidth: max(3, s.width / 300), mosaic: mosaic)
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
