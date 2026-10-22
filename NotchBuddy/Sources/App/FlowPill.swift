#if !APPSTORE
import AppKit
import SwiftUI

/// The edge of the screen the pill lives on, centred on it.
enum FlowPillEdge: String, CaseIterable, Identifiable {
    case bottom, left, right
    var id: String { rawValue }

    var label: String {
        switch self {
        case .bottom: return String(localized: "flow.edge.bottom")
        case .left:   return String(localized: "flow.edge.left")
        case .right:  return String(localized: "flow.edge.right")
        }
    }
}

/// A message above the pill: something went wrong, or something is ready, with a button to act.
struct FlowAnnouncement: Equatable, Identifiable {
    let id = UUID()
    /// An SF Symbol.
    var symbol: String
    /// Its colour.
    var tint: String = "#FB923C"
    var text: String
    /// The button's title, if there is something to do.
    var action: String?
}

/// What the pill shows.
@MainActor
final class FlowPillModel: ObservableObject {
    enum Phase: Equatable {
        /// Resting: a small pill at the bottom of the screen, there as long as Flow dictation is on.
        case idle
        /// The key is held: the pill opens, Mochi on the left, the dots follow the voice.
        case listening
        /// Hands-free (double tap, or the pill's microphone): ✕, the dots and ✓, with an orange ring.
        case locked
        /// Released: the Mac turns the voice into words.
        case thinking
        /// No Accessibility permission: the words are on the clipboard.
        case copied
        /// The microphone or speech recognition could not start.
        case failed
        /// ⌃⌘V: the last dictation was pasted again.
        case pastedAgain
    }
    @Published var phase: Phase = .idle
    /// A call is being recorded by the Notetaker: resting, the pill shows it, with a stop button.
    @Published var noteStartedAt: Date?
    /// The pointer is over the pill: resting, it opens into its buttons.
    @Published var hovered = false
    /// The bubble above the pill while the pointer is on one of its buttons.
    @Published var tooltip: String?
    /// The message above the pill.
    @Published var announcement: FlowAnnouncement?
    /// The key to dictate ("⌥ de droite"), for the bubbles.
    @Published var keyLabel = ""
    /// Where the pill is: along the bottom, or standing on the left or right edge.
    @Published var edge: FlowPillEdge = .bottom
    /// The recorded call has passed an hour: the time needs a little more room.
    @Published var noteHours = false

    var stopNote: (@MainActor () -> Void)?
    var toggleNote: (@MainActor () -> Void)?
    var dictate: (@MainActor () -> Void)?
    var finishDictation: (@MainActor () -> Void)?
    var cancelDictation: (@MainActor () -> Void)?
    var openHub: (@MainActor () -> Void)?
    var announcementAction: (@MainActor () -> Void)?
    var dismissAnnouncement: (@MainActor () -> Void)?
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

/// The pill at the bottom of the screen, like Wispr Flow's bar. Resting, it is a small see-through
/// pill; under the pointer it opens into Mochi and three buttons (dictate, record a call, open
/// Coucou), each with its bubble. When you speak it opens into Mochi and nine dots rising and
/// falling with the graves and the aigus of the voice. Messages (a paste that could not happen, a
/// call's notes ready) grow above it, with a button to act.
struct FlowPillView: View {
    @ObservedObject var model: FlowPillModel
    let bands: FlowAudioBands
    let smoother: FlowLevelSmoother

    /// The resting pill, lying along its edge.
    static let restingLength: CGFloat = 44
    static let restingThickness: CGFloat = 8
    static let openThickness: CGFloat = 34

    /// What the capsule shows, from the most to the least important.
    enum Look: Equatable {
        case resting, toolbar, note, live, handsFree, message
    }

    private var look: Look {
        switch model.phase {
        case .locked: return .handsFree
        case .listening, .thinking: return .live
        case .copied, .failed, .pastedAgain: return .message
        case .idle:
            if model.noteStartedAt != nil { return .note }
            return model.hovered ? .toolbar : .resting
        }
    }

    private var open: Bool { look != .resting }
    /// On the left or right edge, the pill stands up and everything in it is stacked.
    private var vertical: Bool { model.edge != .bottom }

    var body: some View {
        let size = FlowPillController.size(for: model.edge)
        Group {
            switch model.edge {
            case .bottom:
                VStack(spacing: 8) {
                    Spacer(minLength: 0)
                    bubble
                    capsule
                }
            case .left:
                HStack(spacing: 8) {
                    capsule
                    bubble
                    Spacer(minLength: 0)
                }
            case .right:
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    bubble
                    capsule
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(.spring(response: 0.34, dampingFraction: 0.78), value: model.announcement)
        .animation(.easeOut(duration: 0.15), value: model.tooltip)
    }

    // MARK: Beside the pill

    /// Where the bubbles grow from: the pill's side.
    private var bubbleAnchor: UnitPoint {
        switch model.edge {
        case .bottom: return .bottom
        case .left:   return .leading
        case .right:  return .trailing
        }
    }

    /// A short message of the pill (pasted again, microphone off…): in the pill when it lies along
    /// the bottom, in a bubble beside it when it stands up.
    private var messageText: String? {
        switch model.phase {
        case .copied:      return String(localized: "flow.copied-noaccess")
        case .failed:      return String(localized: "flow.failed")
        case .pastedAgain: return String(localized: "flow.pasted-again")
        default:           return nil
        }
    }

    @ViewBuilder private var bubble: some View {
        if let announcement = model.announcement {
            FlowAnnouncementView(announcement: announcement,
                                 act: { model.announcementAction?() },
                                 dismiss: { model.dismissAnnouncement?() })
                .transition(.scale(scale: 0.6, anchor: bubbleAnchor).combined(with: .opacity))
        } else if let text = model.tooltip ?? (vertical ? messageText : nil) {
            Text(text)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(Capsule().fill(Color.black.opacity(0.94)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.14)))
                .fixedSize()
                .transition(.scale(scale: 0.8, anchor: bubbleAnchor).combined(with: .opacity))
        }
    }

    // MARK: The capsule

    /// How long the open pill is, along its edge, for what it shows.
    private var openLength: CGFloat {
        switch look {
        case .toolbar:   return 150
        case .note:      return vertical ? 128 : (model.noteHours ? 152 : 136)
        case .handsFree: return 158
        case .message:
            if vertical { return 76 }
            return Self.messageWidth(messageText ?? "")
        default:         return 118
        }
    }

    static func messageWidth(_ text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let w = (text as NSString).size(withAttributes: [.font: font]).width
        return ceil(w) + 22 + 9 + 26 + 2
    }

    private var capsule: some View {
        let length = open ? openLength : Self.restingLength
        let thickness = open ? Self.openThickness : Self.restingThickness
        return ZStack {
            // Resting, the pill is see-through: whatever is behind it stays readable. Open, it is black.
            Capsule()
                .fill(Color.black.opacity(open ? 0.94 : 0.28))
            Capsule()
                .strokeBorder(Color.white.opacity(open ? 0.16 : 0.42), lineWidth: open ? 1 : 1.2)
            Capsule()
                .strokeBorder(Color(hex: "#F97316").opacity(look == .handsFree ? 0.85 : 0), lineWidth: 1.5)
            content
                .opacity(open ? 1 : 0)
                .scaleEffect(open ? 1 : 0.5)
                .animation(open ? .easeOut(duration: 0.2).delay(0.07) : .easeIn(duration: 0.1), value: open)
        }
        .frame(width: vertical ? thickness : length, height: vertical ? length : thickness)
        .clipShape(Capsule())          // the content stays inside while the pill opens
        .shadow(color: .black.opacity(open ? 0.35 : 0), radius: open ? 10 : 0, y: open ? 4 : 0)
        .animation(.spring(response: 0.36, dampingFraction: 0.74), value: look)
        .padding(model.edge == .bottom ? .bottom : (model.edge == .left ? .leading : .trailing), 2)
    }

    /// The pieces of the pill, in a row along the bottom, in a column on the sides.
    @ViewBuilder private func line<Content: View>(spacing: CGFloat, @ViewBuilder _ pieces: () -> Content) -> some View {
        if vertical {
            VStack(spacing: spacing) { pieces() }
        } else {
            HStack(spacing: spacing) { pieces() }
        }
    }

    @ViewBuilder private var content: some View {
        switch look {
        case .toolbar:
            line(spacing: 4) {
                mochi.padding(vertical ? .bottom : .trailing, 5)
                PillButton(symbol: "mic.fill", tip: String(format: String(localized: "flow.tip.dictate %@"), model.keyLabel),
                           model: model) { model.dictate?() }
                PillButton(symbol: "record.circle", tip: String(localized: "flow.tip.note"), model: model) {
                    model.toggleNote?()
                }
                PillButton(symbol: "macwindow", tip: String(localized: "flow.tip.hub"), model: model) { model.openHub?() }
            }
            .padding(vertical ? .vertical : .horizontal, 10)
            .fixedSize()
        case .handsFree:
            line(spacing: 9) {
                PillButton(symbol: "xmark", tip: String(localized: "flow.tip.cancel"), model: model, small: true) {
                    model.cancelDictation?()
                }
                dots
                PillButton(symbol: "checkmark", tip: String(format: String(localized: "flow.tip.finish %@"), model.keyLabel),
                           model: model, small: true, filled: true) { model.finishDictation?() }
            }
            .padding(vertical ? .vertical : .horizontal, 6)
            .fixedSize()
        case .message where vertical:
            line(spacing: 9) {
                mochi
                Image(systemName: model.phase == .failed ? "mic.slash.fill" : "doc.on.clipboard.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(hex: "#E8E9EC"))
            }
            .padding(.vertical, 13)
            .fixedSize()
        default:
            line(spacing: vertical ? 7 : 9) {
                mochi
                switch model.phase {
                case .copied, .failed, .pastedAgain:
                    Text(messageText ?? "")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(hex: "#E8E9EC"))
                        .fixedSize()
                case .idle:
                    noteContent
                default:
                    dots
                }
            }
            .padding(vertical ? .vertical : .horizontal, vertical ? 10 : 13)
            .fixedSize()
        }
    }

    /// Mochi, drawn by the same engine as the compact island's mini Mochis: his eyes wander all
    /// around while you speak. 22 pt wide like a pill's Mochi (the canvas is larger, as there).
    private var mochi: some View {
        // Still while only a recorded call shows: the pill costs nothing during a long call.
        FlowMochiView(active: model.phase != .idle || model.hovered)
            .frame(width: 22 / 0.6, height: 22 / 0.6)
            .frame(width: 22, height: 22, alignment: .center)
    }

    /// A call being recorded: a red dot, the time, and a button to stop.
    @ViewBuilder private var noteContent: some View {
        if let start = model.noteStartedAt {
            line(spacing: vertical ? 6 : 8) {
                Circle()
                    .fill(Color(hex: "#FF453A"))
                    .frame(width: 8, height: 8)
                    .shadow(color: Color(hex: "#FF453A").opacity(0.6), radius: 3)
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Text(NoteBuilder.clock(context.date.timeIntervalSince(start)))
                        .font(.system(size: vertical ? 10 : 12, weight: .semibold).monospacedDigit())
                        .foregroundColor(Color(hex: "#E8E9EC"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: vertical ? 30 : nil)
                }
                Button { model.stopNote?() } label: {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white)
                        .frame(width: 8, height: 8)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.16)))
                }
                .buttonStyle(.plain)
                .help(String(localized: "notes.stop"))
            }
        }
    }

    /// Nine dots, graves to aigus: across the pill along the bottom, down it on the sides.
    @ViewBuilder private var dots: some View {
        if vertical {
            bars
                .frame(width: Self.barsLength, height: 22)
                .rotationEffect(.degrees(90))
                .frame(width: 22, height: Self.barsLength)
        } else {
            bars
        }
    }

    static let barsLength: CGFloat = CGFloat(FlowBands.count) * 3.4 + CGFloat(FlowBands.count - 1) * 3.2

    private var bars: some View {
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

/// A round button of the pill, with its bubble above while the pointer is on it.
private struct PillButton: View {
    let symbol: String
    let tip: String
    @ObservedObject var model: FlowPillModel
    var small = false
    var filled = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: small ? 10 : 12, weight: .bold))
                .foregroundColor(filled ? .black : .white)
                .frame(width: small ? 24 : 28, height: small ? 24 : 28)
                .background(Circle().fill(filled ? Color.white : Color.white.opacity(hover ? 0.22 : 0.10)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tip)
        .onHover { inside in
            hover = inside
            if inside { model.tooltip = tip } else if model.tooltip == tip { model.tooltip = nil }
        }
    }
}

/// The message above the pill: a symbol, the words, a button to act and one to close.
private struct FlowAnnouncementView: View {
    let announcement: FlowAnnouncement
    let act: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: announcement.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Color(hex: announcement.tint))
            Text(announcement.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 270, alignment: .leading)
            if let action = announcement.action {
                Button(action: act) {
                    Text(action)
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 13)
                        .frame(height: 28)
                        .background(Capsule().fill(Color(hex: "#F5F1EA")))
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Color.white.opacity(0.6))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "flow.ann.dismiss"))
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black.opacity(0.95)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
        .fixedSize()
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

/// The pill's window: borderless, never takes the focus (the words go to the app you type in), on
/// every Space and over full-screen apps. It stays at the bottom centre of a screen while Flow
/// dictation is on, and moves to the screen the mouse is on when you speak. It is taller than the
/// pill, for the bubbles above it, and lets clicks through except where the pill and its bubble are.
@MainActor
final class FlowPillController {
    /// The panel: wide along the bottom (bubbles above the pill), tall on the sides (bubbles beside it).
    static func size(for edge: FlowPillEdge) -> NSSize {
        edge == .bottom ? NSSize(width: 520, height: 170) : NSSize(width: 480, height: 320)
    }

    private var size: NSSize { Self.size(for: model.edge) }

    let model = FlowPillModel()
    private let smoother = FlowLevelSmoother()
    private let bands: FlowAudioBands
    private var panel: NSPanel?
    private var restTask: Task<Void, Never>?
    private var announceTask: Task<Void, Never>?
    private var unhoverTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var mouseMonitors: [Any] = []

    /// Whether Flow dictation is on (the resting pill shows).
    private var dictationOn = false

    init(bands: FlowAudioBands) {
        self.bands = bands
        model.stopNote = { NoteTaker.shared.stop() }
        model.dismissAnnouncement = { [weak self] in self?.dismissAnnouncement() }
    }

    private var shouldShow: Bool { dictationOn || model.noteStartedAt != nil || model.announcement != nil }

    /// The Notetaker records (a date) or stopped (nil): the pill shows it even when dictation is off.
    func setNote(_ start: Date?) {
        model.noteStartedAt = start
        model.noteHours = false
        noteHoursTask?.cancel()
        if let start {
            noteHoursTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(max(0, 3600 - Date().timeIntervalSince(start))))
                guard !Task.isCancelled, let self, self.model.noteStartedAt == start else { return }
                self.model.noteHours = true
            }
        }
        updateVisibility()
    }

    private var noteHoursTask: Task<Void, Never>?

    /// Moves the pill to another edge of the screen.
    func setEdge(_ edge: FlowPillEdge) {
        guard edge != model.edge || panel == nil else { return }
        model.edge = edge
        model.tooltip = nil
        guard let panel else { return }
        panel.setContentSize(size)
        panel.contentView?.frame = NSRect(origin: .zero, size: size)
        place(panel, onMouseScreen: false)
        updateMouse()
    }

    /// Flow dictation on: the resting pill shows. Off: it goes away.
    func setEnabled(_ on: Bool) {
        restTask?.cancel()
        model.phase = .idle
        dictationOn = on
        updateVisibility()
    }

    private func updateVisibility() {
        if shouldShow {
            if panel == nil { build() }
            guard let panel else { return }
            if !panel.isVisible {
                place(panel, onMouseScreen: false)
                panel.orderFrontRegardless()
            }
            watchMouse()
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
            stopWatchingMouse()
            model.hovered = false
            model.tooltip = nil
            if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
            screenObserver = nil
        }
    }

    // MARK: - Messages

    /// A message above the pill, with a button to act; it goes away by itself after a while,
    /// unless the pointer is on it.
    func announce(_ announcement: FlowAnnouncement, for seconds: TimeInterval = 8,
                  perform: (@MainActor () -> Void)? = nil) {
        model.tooltip = nil
        model.announcementAction = { [weak self] in
            perform?()
            self?.dismissAnnouncement()
        }
        model.announcement = announcement
        updateVisibility()
        updateMouse()
        announceTask?.cancel()
        announceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            while !Task.isCancelled, self?.model.hovered == true {
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            self?.dismissAnnouncement()
        }
    }

    func dismissAnnouncement() {
        announceTask?.cancel()
        model.announcement = nil
        model.announcementAction = nil
        updateVisibility()
        updateMouse()
    }

    // MARK: - The pointer

    /// The panel takes clicks only where the pill and its bubble are; the pill opens under the pointer.
    private func watchMouse() {
        guard mouseMonitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMouse() }
        }) { mouseMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.updateMouse() }
            return event
        }) { mouseMonitors.append(local) }
        updateMouse()
    }

    private func stopWatchingMouse() {
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }
        mouseMonitors.removeAll()
        panel?.ignoresMouseEvents = true
    }

    /// The parts of the panel that take the pointer, in screen coordinates.
    private func hotRects(_ frame: NSRect) -> [NSRect] {
        let open = model.hovered || model.phase != .idle || model.noteStartedAt != nil
        // The pill: a generous zone around the small resting one, the whole capsule once open.
        let length: CGFloat = open ? 200 : 96
        let thickness: CGFloat = open ? 46 : 26
        let bubble = model.announcement != nil || model.tooltip != nil
        switch model.edge {
        case .bottom:
            var rects = [NSRect(x: frame.midX - length / 2, y: frame.minY, width: length, height: thickness)]
            if model.announcement != nil {
                rects.append(NSRect(x: frame.midX - 240, y: frame.minY + 40, width: 480, height: 110))
            } else if bubble {
                rects.append(NSRect(x: frame.midX - 140, y: frame.minY + 40, width: 280, height: 40))
            }
            return rects
        case .left, .right:
            let left = model.edge == .left
            let pillX = left ? frame.minX : frame.maxX - thickness
            var rects = [NSRect(x: pillX, y: frame.midY - length / 2, width: thickness, height: length)]
            if bubble {
                let width: CGFloat = model.announcement != nil ? frame.width - 40 : 300
                let height: CGFloat = model.announcement != nil ? 130 : 44
                let x = left ? frame.minX + 40 : frame.maxX - 40 - width
                rects.append(NSRect(x: x, y: frame.midY - height / 2, width: width, height: height))
            }
            return rects
        }
    }

    private func updateMouse() {
        guard let panel, panel.isVisible else { return }
        let mouse = NSEvent.mouseLocation
        let over = hotRects(panel.frame).contains { NSMouseInRect(mouse, $0, false) }
        if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
        if over {
            unhoverTask?.cancel()
            unhoverTask = nil
            if !model.hovered { model.hovered = true }
        } else if model.hovered, unhoverTask == nil {
            // A short grace, to move from the pill to its bubble.
            unhoverTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                self.unhoverTask = nil
                let mouse = NSEvent.mouseLocation
                if let panel = self.panel, self.hotRects(panel.frame).contains(where: { NSMouseInRect(mouse, $0, false) }) { return }
                self.model.hovered = false
                self.model.tooltip = nil
                self.panel?.ignoresMouseEvents = true
            }
        }
    }

    // MARK: - Dictation

    /// The key is down: open on the screen the mouse is on.
    func listen() {
        restTask?.cancel()
        if panel == nil { build() }
        guard let panel else { return }
        place(panel, onMouseScreen: true)
        panel.orderFrontRegardless()
        smoother.reset()
        model.tooltip = nil
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
            self.model.tooltip = nil
            self.updateMouse()
        }
    }

    private func build() {
        let view = NSHostingView(rootView: FlowPillView(model: model, bands: bands, smoother: smoother))
        view.frame = NSRect(origin: .zero, size: size)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
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
        let size = self.size
        switch model.edge {
        case .bottom:
            // Just above the Dock (or the bottom edge when the Dock hides).
            panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.minY + 4))
        case .left:
            panel.setFrameOrigin(NSPoint(x: area.minX + 4, y: area.midY - size.height / 2))
        case .right:
            panel.setFrameOrigin(NSPoint(x: area.maxX - size.width - 4, y: area.midY - size.height / 2))
        }
    }
}
#endif
