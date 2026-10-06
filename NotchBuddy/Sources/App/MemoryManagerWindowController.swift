import AppKit
import SwiftUI

@MainActor
final class MemoryManagerWindowController: NSWindowController {
    static let shared = MemoryManagerWindowController()
    let model: MemoryManagerModel
    private var presentation = MemoryManagerPresentationState()

    private init() {
        model = MemoryManagerModel()
        let descriptor = memoryManagerWindowConfiguration()
        let style: NSWindow.StyleMask = descriptor.isResizable
            ? [.titled, .closable, .miniaturizable, .resizable]
            : [.titled, .closable, .miniaturizable]
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        window.title = "Memory Manager — Coucou"
        window.contentMinSize = NSSize(width: 760, height: 480)
        window.isReleasedWhenClosed = descriptor.isReleasedWhenClosed
        window.contentView = NSHostingView(rootView: MemoryManagerView(model: model))
        window.center()
        super.init(window: window)
        window.setFrameAutosaveName(descriptor.frameAutosaveName)
        shouldCascadeWindows = false
    }

    required init?(coder: NSCoder) { nil }

    func present(query: String? = nil, documentIds: [String] = []) {
        if !documentIds.isEmpty { model.setPendingDocumentIds(documentIds) }
        else { presentation.present(query: query); if let pending = presentation.consumePendingQuery() { model.setPendingQuery(pending) } }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
