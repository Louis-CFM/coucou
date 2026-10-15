#if !APPSTORE
import AppKit
import SwiftUI

/// What the pill shows.
@MainActor
final class FlowPillModel: ObservableObject {
    enum Phase: Equatable {
        /// Resting: a small pill at the bottom of the screen, there as long as Flow dictation is on.
        case idle
        /// The key is held: the pill opens, Mochi on the left, the dots follow the voice.
        case listening
        /// Hands-free (double tap): same, with an orange ring.
        case locked
        /// Released: the Mac turns the voice into words.
        case thinking
        /// No Accessibility permission: the words are on the clipboard.
        case copied
        /// The microphone or speech recognition could not start.
        case failed
    }
    @Published var phase: Phase = .idle
}

/// Eases the dots toward the microphone's levels, frame by frame (fast up, slower down), and
/// makes them ripple while the Mac turns the voice into words.
final class FlowLevelSmoother {
    private var values = [Double](repeating: 0, count: FlowBands.count)
    private var last: Date?

    func frame(at date: Date, target: [Float]?, thinking: Bool) -> [Double] {
        let dt = min(0.1, last.map { date.timeIntervalSince($0) } ?? 1.0 / 60)
        last = date
        let t = date.timeIntervalSinceReferenceDate
        for i in values.indices {
            var goal: Double
            if thinking {
                // A small wave running through the dots.
                goal = 0.10 + 0.22 * max(0, sin(t * 7.5 - Double(i) * 0.75))
            } else {
                let level = Double(target?[safe: i] ?? 0)
                // A touch of life so a steady sound does not freeze the dots.
                goal = level * (0.86 + 0.14 * sin(t * 11 + Double(i) * 1.7))
            }
            let rate = goal > values[i] ? 28.0 : 10.0
            values[i] += (goal - values[i]) * min(1, rate * dt)
        }
        return values
    }

    func reset() {
        values = [Double](repeating: 0, count: FlowBands.count)
        last = nil
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// The pill at the bottom of the screen, like Wispr Flow's bar. Resting, it is a small black pill
/// with a light outline; when you speak it opens from there into a capsule with a tiny Mochi on
/// the left and nine dots on the right that rise and fall with the graves and the aigus of the voice.
struct FlowPillView: View {
    @ObservedObject var model: FlowPillModel
    let bands: FlowAudioBands
    let smoother: FlowLevelSmoother

    static let restingSize = CGSize(width: 44, height: 8)
    static let openHeight: CGFloat = 34

    private var open: Bool { model.phase != .idle }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            capsule
        }
        .frame(width: FlowPillController.size.width, height: FlowPillController.size.height)
    }

    /// The width the open pill needs for what it shows.
    private var openWidth: CGFloat {
        switch model.phase {
        case .copied: return Self.messageWidth(String(localized: "flow.copied-noaccess"))
        case .failed: return Self.messageWidth(String(localized: "flow.failed"))
        default:      return 118
        }
    }

    static func messageWidth(_ text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let w = (text as NSString).size(withAttributes: [.font: font]).width
        return ceil(w) + 22 + 9 + 26 + 2
    }

    private var capsule: some View {
        ZStack {
            // Resting, the pill is see-through: whatever is behind it stays readable. Open, it is black.
            Capsule()
                .fill(Color.black.opacity(open ? 0.94 : 0.28))
            Capsule()
                .strokeBorder(Color.white.opacity(open ? 0.16 : 0.42), lineWidth: open ? 1 : 1.2)
            Capsule()
                .strokeBorder(Color(hex: "#F97316").opacity(model.phase == .locked ? 0.85 : 0), lineWidth: 1.5)
            content
                .opacity(open ? 1 : 0)
                .scaleEffect(open ? 1 : 0.5)
                .animation(open ? .easeOut(duration: 0.2).delay(0.07) : .easeIn(duration: 0.1), value: open)
        }
        .frame(width: open ? openWidth : Self.restingSize.width,
               height: open ? Self.openHeight : Self.restingSize.height)
        .clipShape(Capsule())          // the content stays inside while the pill opens
        .shadow(color: .black.opacity(open ? 0.35 : 0), radius: open ? 10 : 0, y: open ? 4 : 0)
        .animation(.spring(response: 0.36, dampingFraction: 0.74), value: model.phase)
        .padding(.bottom, 2)
    }

    private var content: some View {
        HStack(spacing: 9) {
            mochi
            switch model.phase {
            case .copied:
                Text("flow.copied-noaccess")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(hex: "#E8E9EC"))
                    .fixedSize()
            case .failed:
                Text("flow.failed")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(hex: "#E8E9EC"))
                    .fixedSize()
            default:
                dots
            }
        }
        .padding(.horizontal, 13)
        .fixedSize()
    }

    /// Mochi, drawn by the same engine as the compact island's mini Mochis: his eyes wander all
    /// around while you speak. 22 pt wide like a pill's Mochi (the canvas is larger, as there).
    private var mochi: some View {
        FlowMochiView(active: open)
            .frame(width: 22 / 0.6, height: 22 / 0.6)
            .frame(width: 22, height: 22, alignment: .center)
    }

    private var dots: some View {
        let active = model.phase == .listening || model.phase == .locked || model.phase == .thinking
        return TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !active)) { context in
            let levels = smoother.frame(at: context.date,
                                        target: model.phase == .thinking ? nil : bands.levels,
                                        thinking: model.phase == .thinking)
            HStack(alignment: .center, spacing: 3.2) {
                ForEach(0..<FlowBands.count, id: \.self) { i in
                    Capsule()
                        .fill(Color.white.opacity(0.94))
                        .frame(width: 3.4, height: 3.4 + 16 * CGFloat(levels[i]))
                }
            }
            .frame(height: 22)
        }
    }
}

/// The pill's Mochi: a mini Mochi (BotEngine, like the pills of the compact island), white, idle,
/// so his eyes wander around. Drawn only while the pill is open.
private struct FlowMochiView: View {
    let active: Bool
    @StateObject private var engine: BotEngine

    init(active: Bool) {
        self.active = active
        _engine = StateObject(wrappedValue: {
            let e = BotEngine()
            e.isMini = true
            e.bodyColor = cgColorFromHex("#F5F6F8")
            return e
        }())
    }

    var body: some View {
        TimelineView(.animation(paused: !active)) { timeline in
            let frame = timeline.date   // redraw on every tick, as in MiniBotCanvasView
            Canvas { context, size in
                _ = frame
                MochiFrameClock.advance(engine)
                engine.draw(context: context, size: size)
            }
        }
        .onAppear { engine.setState(.idle, force: true) }
    }
}

/// The pill's window: borderless, never takes the focus (the words go to the app you type in),
/// lets clicks through, on every Space and over full-screen apps. It stays at the bottom centre of
/// a screen while Flow dictation is on, and moves to the screen the mouse is on when you speak.
@MainActor
final class FlowPillController {
    static let size = NSSize(width: 380, height: 60)

    let model = FlowPillModel()
    private let smoother = FlowLevelSmoother()
    private let bands: FlowAudioBands
    private var panel: NSPanel?
    private var restTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?

    init(bands: FlowAudioBands) {
        self.bands = bands
    }

    /// Flow dictation on: the resting pill shows. Off: it goes away.
    func setEnabled(_ on: Bool) {
        restTask?.cancel()
        model.phase = .idle
        if on {
            if panel == nil { build() }
            if let panel { place(panel, onMouseScreen: false); panel.orderFrontRegardless() }
            if screenObserver == nil {
                screenObserver = NotificationCenter.default.addObserver(
                    forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let panel = self.panel, panel.isVisible else { return }
                        self.place(panel, onMouseScreen: false)
                    }
                }
            }
        } else {
            panel?.orderOut(nil)
            if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
            screenObserver = nil
        }
    }

    /// The key is down: open on the screen the mouse is on.
    func listen() {
        restTask?.cancel()
        if panel == nil { build() }
        guard let panel else { return }
        place(panel, onMouseScreen: true)
        panel.orderFrontRegardless()
        smoother.reset()
        model.phase = .listening
    }

    /// A short message, then back to rest.
    func flash(_ phase: FlowPillModel.Phase) {
        restTask?.cancel()
        model.phase = phase
        rest(after: 1.8)
    }

    /// Back to the small resting pill.
    func rest(after delay: TimeInterval = 0) {
        restTask?.cancel()
        restTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            self.model.phase = .idle
        }
    }

    private func build() {
        let view = NSHostingView(rootView: FlowPillView(model: model, bands: bands, smoother: smoother))
        view.frame = NSRect(origin: .zero, size: Self.size)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.contentView = view
        panel = p
    }

    private func place(_ panel: NSPanel, onMouseScreen: Bool) {
        let mouse = NSEvent.mouseLocation
        let screen = onMouseScreen
            ? (NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main)
            : (panel.screen ?? NSScreen.main)
        guard let area = screen?.visibleFrame else { return }
        // Just above the Dock (or the bottom edge when the Dock hides).
        panel.setFrameOrigin(NSPoint(x: area.midX - Self.size.width / 2, y: area.minY + 4))
    }
}
#endif
