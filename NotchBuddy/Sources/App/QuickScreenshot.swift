#if !APPSTORE
import AppKit

/// ⌘⇧2: the whole screen in one press. The picture goes to two places at once:
/// - the clipboard, so ⌘V pastes it straight into a chat (⌃V in Claude Code's terminal);
/// - a thumbnail in the screen's bottom right corner, the way macOS shows its own screenshots:
///   drag it where you like (a chat, a folder, a mail), click it to open it, swipe it to the right
///   to put it away. It goes by itself after a few seconds, unless the pointer rests on it.
///
/// The screen is the one the pointer is on. The image stays on the Mac, in the temporary folder
/// Coucou keeps its captures in (the last 20 of them).
@MainActor
final class QuickScreenshot {
    static let shared = QuickScreenshot()

    private var running = false
    private var thumbnail: ScreenshotThumbnail? = nil

    /// The same folder as ⌘⇧S's captures.
    private static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CoucouCaptures", isDirectory: true)
    }

    private init() {}

    func take() {
        guard !running else { return }
        guard CGPreflightScreenCaptureAccess() else {
            appendAppLog("nb.log", "[Screenshot] no Screen Recording permission: asking")
            _ = CGRequestScreenCaptureAccess()
            AppState.shared.noteMessage = String(localized: "capture.permission")
            NotificationCenter.default.post(name: .hookExpand, object: IslandView.note)
            return
        }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main,
              let primary = NSScreen.screens.first else { return }
        // screencapture's -R counts from the top left corner of the main screen.
        let f = screen.frame
        let rect = [f.minX, primary.frame.maxY - f.maxY, f.width, f.height].map { String(Int($0.rounded())) }.joined(separator: ",")
        let corner = screen.visibleFrame
        // The last thumbnail and the open island must not be in the picture.
        thumbnail?.close(animated: false)
        thumbnail = nil
        let wasOpen = AppState.shared.mode == .expanded
        if wasOpen {
            NotificationCenter.default.post(name: .islandCollapse, object: nil)
        }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let file = Self.folder.appendingPathComponent("Screenshot \(formatter.string(from: Date())).png")
        running = true
        Task { @MainActor in
            if wasOpen { try? await Task.sleep(for: .milliseconds(320)) }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            // No -x: the Mac's own shutter sound, as with ⌘⇧3.
            task.arguments = ["-R", rect, file.path]
            task.terminationHandler = { _ in
                Task { @MainActor in QuickScreenshot.shared.finished(file, corner: corner) }
            }
            do {
                try task.run()
                appendAppLog("nb.log", "[Screenshot] capturing \(rect)")
            } catch {
                self.running = false
                appendAppLog("nb.log", "[Screenshot] screencapture failed: \(error)")
            }
        }
    }

    private func finished(_ file: URL, corner: NSRect) {
        running = false
        guard let png = try? Data(contentsOf: file), let image = NSImage(data: png) else {
            appendAppLog("nb.log", "[Screenshot] no image")
            return
        }
        CapturePaste.put(png: png, image: image, transient: false)
        let shot = ScreenshotThumbnail(url: file, png: png, image: image, corner: corner)
        shot.onClose = { [weak self, weak shot] in
            if let self, self.thumbnail === shot { self.thumbnail = nil }
        }
        thumbnail = shot
        shot.show()
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.surprised)
        appendAppLog("nb.log", "[Screenshot] copied, thumbnail shown")
        prune(keeping: file)
    }

    /// Keeps the last 20 captures, and never the one on the island or on screen.
    private func prune(keeping current: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a > b
        }
        for old in sorted.dropFirst(20) where old != current && old != ScreenCapture.shared.url {
            try? fm.removeItem(at: old)
        }
    }
}

// MARK: - The thumbnail

/// A small panel in the bottom right corner, above the Dock, that never takes the focus: the app
/// you were in stays in front, ready for ⌘V.
@MainActor
final class ScreenshotThumbnail {
    let url: URL
    let png: Data
    let image: NSImage
    var onClose: (@MainActor () -> Void)? = nil

    private let panel: NSPanel
    private let home: NSRect
    private var timer = 0
    private var hovering = false
    private var dragging = false
    private var closed = false

    private static let margin: CGFloat = 18
    private static let maxSize = NSSize(width: 210, height: 150)
    /// How long it stays, and again after the pointer leaves it.
    private static let stay: Double = 6
    private static let stayAfterHover: Double = 3

    init(url: URL, png: Data, image: NSImage, corner: NSRect) {
        self.url = url
        self.png = png
        self.image = image
        let s = image.size
        let scale = min(Self.maxSize.width / max(1, s.width), Self.maxSize.height / max(1, s.height))
        let size = NSSize(width: (s.width * scale).rounded(), height: (s.height * scale).rounded())
        home = NSRect(x: corner.maxX - Self.margin - size.width, y: corner.minY + Self.margin,
                      width: size.width, height: size.height)
        panel = NSPanel(contentRect: home, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        let view = ScreenshotThumbnailView(frame: NSRect(origin: .zero, size: size), image: image)
        panel.contentView = view
        view.owner = self
    }

    func show() {
        panel.setFrame(home.offsetBy(dx: 40, dy: 0), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(home, display: true)
            panel.animator().alphaValue = 1
        }
        panel.invalidateShadow()
        schedule(after: Self.stay)
    }

    func close(animated: Bool) {
        guard !closed else { return }
        closed = true
        timer += 1
        guard animated else {
            panel.orderOut(nil)
            onClose?()
            return
        }
        let away = panel.frame.offsetBy(dx: 60, dy: 0)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(away, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                self.panel.orderOut(nil)
                self.onClose?()
            }
        })
    }

    private func schedule(after seconds: Double) {
        timer += 1
        let token = timer
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, self.timer == token, !self.hovering, !self.dragging else { return }
            self.close(animated: true)
        }
    }

    // MARK: Called by the view

    func hover(_ inside: Bool) {
        hovering = inside
        if inside { timer += 1 } else if !dragging && !closed { schedule(after: Self.stayAfterHover) }
    }

    /// Click: the screenshot opens (Preview).
    func open() {
        NSWorkspace.shared.open(url)
        close(animated: false)
    }

    /// Swipe to the right: it follows the pointer.
    func swipe(_ dx: CGFloat) {
        let d = max(0, dx)
        panel.setFrameOrigin(NSPoint(x: home.minX + d, y: home.minY))
        panel.alphaValue = max(0.2, 1 - d / 220)
    }

    /// Far enough, it goes; otherwise it comes back.
    func swipeEnded(_ dx: CGFloat) {
        if dx > 50 {
            close(animated: true)
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(home, display: true)
            panel.animator().alphaValue = 1
        }
    }

    /// While it's dragged, only the picture under the pointer shows, as on macOS.
    func dragBegan() {
        dragging = true
        timer += 1
        panel.alphaValue = 0
    }

    /// Dropped somewhere: done. Let go over nothing: it comes back.
    func dragEnded(dropped: Bool) {
        dragging = false
        if dropped {
            close(animated: false)
        } else {
            panel.alphaValue = 1
            schedule(after: Self.stayAfterHover)
        }
    }
}

/// The picture, with the round corners and the thin light edge of macOS's own thumbnail. Click,
/// swipe to the right, or drag it out.
final class ScreenshotThumbnailView: NSView, NSDraggingSource {
    weak var owner: ScreenshotThumbnail?
    private let image: NSImage
    private var downAt: NSPoint? = nil
    private enum Gesture { case none, swipe, drag }
    private var gesture = Gesture.none

    init(frame: NSRect, image: NSImage) {
        self.image = image
        super.init(frame: frame)
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resizeAspectFill
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.45).cgColor
        layer?.backgroundColor = NSColor.black.cgColor
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) { owner?.hover(true) }
    override func mouseExited(with event: NSEvent) { owner?.hover(false) }

    override func mouseDown(with event: NSEvent) {
        downAt = NSEvent.mouseLocation
        gesture = .none
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt else { return }
        let p = NSEvent.mouseLocation
        let dx = p.x - start.x, dy = p.y - start.y
        switch gesture {
        case .none:
            guard hypot(dx, dy) > 4 else { return }
            if dx > 0 && abs(dx) > abs(dy) * 1.5 {
                gesture = .swipe
                owner?.swipe(dx)
            } else {
                gesture = .drag
                startDrag(event)
            }
        case .swipe:
            owner?.swipe(dx)
        case .drag:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            downAt = nil
            gesture = .none
        }
        guard let start = downAt else { return }
        switch gesture {
        case .none: owner?.open()
        case .swipe: owner?.swipeEnded(NSEvent.mouseLocation.x - start.x)
        case .drag: break
        }
    }

    /// The file for a folder or a chat that takes files, the PNG for an app that takes images.
    private func startDrag(_ event: NSEvent) {
        guard let owner else { return }
        let item = NSPasteboardItem()
        item.setString(owner.url.absoluteString, forType: .fileURL)
        item.setData(owner.png, forType: .png)
        let drag = NSDraggingItem(pasteboardWriter: item)
        drag.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [drag], event: event, source: self)
        owner.dragBegan()
    }

    nonisolated func draggingSession(_ session: NSDraggingSession,
                                     sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                                     operation: NSDragOperation) {
        let dropped = operation != []
        MainActor.assumeIsolated {
            owner?.dragEnded(dropped: dropped)
        }
    }
}
#endif
