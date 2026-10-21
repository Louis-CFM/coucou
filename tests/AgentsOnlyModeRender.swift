import AppKit
import SwiftUI

@MainActor
final class ModePreviewState: ObservableObject {
    @Published var enabled = false
}

struct InteractiveModePreview: View {
    @ObservedObject var state: ModePreviewState
    var body: some View { AgentsOnlyModeControl(enabled: $state.enabled).padding(24).frame(width: 520) }
}

@main
struct AgentsOnlyModeRender {
    @MainActor static func nativeSwitch(in view: NSView) -> NSSwitch? {
        if let control = view as? NSSwitch { return control }
        return view.subviews.lazy.compactMap { nativeSwitch(in: $0) }.first
    }

    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.finishLaunching()
        let model = ModePreviewState()
        let interactive = NSHostingView(rootView: InteractiveModePreview(state: model))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: interactive.fittingSize), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = interactive
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        interactive.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        guard let control = nativeSwitch(in: interactive) else { fatalError("No native mode switch") }
        control.performClick(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(model.enabled, "The native switch enables agents-only mode")
        control.performClick(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(!model.enabled, "The native switch returns to full mode")
        print("Production mode control: native switch toggled both directions")
        let view = VStack(alignment: .leading, spacing: 20) {
            Text("Coucou · General").font(.title2.bold())
            AgentsOnlyModeControl(enabled: .constant(false))
            AgentsOnlyModeControl(enabled: .constant(true))
        }
        .padding(24)
        .frame(width: 520)
        .background(Color(red: 0.06, green: 0.065, blue: 0.075))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        // A native GroupBox/Switch embeds AppKit views, which ImageRenderer omits.
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        window.contentView = hosting
        window.setContentSize(size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            fatalError("Could not render the actual mode control")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG encoding failed") }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        window.orderOut(nil)
    }
}
