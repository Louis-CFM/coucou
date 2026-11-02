#if !APPSTORE
import AppKit
import SwiftUI

/// The volume / brightness HUD: the compact island's shape (the notch plus its wings),
/// one strip taller. Mochi sits in the left wing where he rests in the compact island,
/// the percentage in the right wing, and the icon and the bar under the notch.
struct SystemHUDView: View {
    @ObservedObject var model: SystemHUDModel

    private static let text = Color(hex: "#F5F6F8")

    var body: some View {
        let width = model.width
        let height = model.height
        let notchHeight = model.notchHeight

        ZStack(alignment: .topLeading) {
            IslandShape(width: width, height: height,
                        cornerRadius: IslandConst.roundedCorner, topRadius: 0)
                .fill(Color.black)

            SystemHUDMochi(model: model)
                .frame(width: 20, height: 20)
                .position(x: 40, y: notchHeight / 2)

            Text(verbatim: "\(SystemHUDLogic.percent(level: model.level, muted: model.muted))%")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundColor(Self.text)
                .position(x: width - 40, y: notchHeight / 2)

            HStack(spacing: 10) {
                Image(systemName: SystemHUDLogic.symbol(for: model.target, level: model.level, muted: model.muted))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Self.text)
                    .frame(width: 18)
                    .contentTransition(.symbolEffect(.replace))
                SystemHUDBar(level: model.muted ? 0 : model.level)
            }
            .padding(.horizontal, 20)
            .frame(width: width, height: SystemHUDController.stripHeight)
            .offset(y: notchHeight)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        // Grows out of the notch, like the island opening.
        .scaleEffect(x: model.visible ? 1 : 0.85, y: model.visible ? 1 : 0.5, anchor: .top)
        .opacity(model.visible ? 1 : 0)
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: model.visible)
    }
}

/// The level bar: a thin capsule, white on a faint track.
struct SystemHUDBar: View {
    let level: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                Capsule()
                    .fill(Color(hex: "#F5F6F8"))
                    .frame(width: max(0, geo.size.width * min(max(level, 0), 1)))
            }
        }
        .frame(height: 6)
        .animation(.spring(response: 0.25, dampingFraction: 0.9), value: level)
    }
}

/// Mochi in the HUD: animated only while the HUD shows, his eyes following the level.
struct SystemHUDMochi: View {
    @ObservedObject var model: SystemHUDModel
    @StateObject private var engine = SystemHUDMochi.makeEngine()

    private static func makeEngine() -> BotEngine {
        let engine = BotEngine()
        engine.isMini = true
        return engine
    }

    var body: some View {
        TimelineView(.animation(paused: !model.visible)) { timeline in
            let frame = timeline.date   // see BotCanvasView: redraw on every tick
            Canvas { context, size in
                _ = frame
                MochiFrameClock.advance(engine)
                engine.draw(context: context, size: size)
            }
        }
        .onAppear {
            engine.setState(.idle, force: true)
            apply(model.mood)
        }
        .onChange(of: model.mood) { _, mood in apply(mood) }
    }

    private func apply(_ mood: SystemHUDMood) {
        let eye: EyeShape?
        switch mood {
        case .normal: eye = nil
        case .max:    eye = .star
        case .min:    eye = .tired
        case .muted:  eye = .closed
        }
        engine.permanentEye = eye
        engine.eyeOverride = eye
        engine.eyeOverrideUntil = eye == nil ? 0 : .greatestFiniteMagnitude
    }
}

/// Settings → Volume & brightness: its own page in the Coucou window.
struct SystemHUDSettingsSection: View {
    @State private var on = SystemHUDController.isEnabled
    @State private var trusted = AXIsProcessTrusted()
    @State private var volume = SystemHUDController.isEnabled(.volume)
    @State private var display = SystemHUDController.isEnabled(.display)
    @State private var keyboard = SystemHUDController.isEnabled(.keyboard)

    var body: some View {
        Group {
            GroupBox(String(localized: "system-hud.title")) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(String(localized: "system-hud.toggle"), isOn: $on)
                        .onChange(of: on) { _, value in
                            SystemHUDController.shared.setEnabled(value)
                            trusted = AXIsProcessTrusted()
                        }
                    Text(String(localized: "system-hud.about"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if on { accessibilityRow }
                    Button(String(localized: "system-hud.preview")) {
                        SystemHUDController.shared.preview()
                    }
                }
                .padding(6)
            }
                .settingsAnchor("systemhud.main")

            GroupBox(String(localized: "system-hud.keys")) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(String(localized: "system-hud.volume"), isOn: $volume)
                        .onChange(of: volume) { _, v in SystemHUDController.setEnabled(v, for: .volume) }
                    Toggle(String(localized: "system-hud.display"), isOn: $display)
                        .onChange(of: display) { _, v in SystemHUDController.setEnabled(v, for: .display) }
                    Toggle(String(localized: "system-hud.keyboard"), isOn: $keyboard)
                        .onChange(of: keyboard) { _, v in SystemHUDController.setEnabled(v, for: .keyboard) }
                    Text(String(localized: "system-hud.keys.footer"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(6)
                .disabled(!on)
            }
                .settingsAnchor("systemhud.keys")
        }
        // While the page shows and Accessibility is missing, notice the moment it is given.
        .task(id: on) {
            while on && !trusted && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                trusted = AXIsProcessTrusted()
            }
        }
        .onAppear { trusted = AXIsProcessTrusted() }
    }

    @ViewBuilder private var accessibilityRow: some View {
        if trusted {
            Label(String(localized: "system-hud.accessibility-ok"), systemImage: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(.green)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "system-hud.needs-accessibility"))
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button(String(localized: "system-hud.open-accessibility")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}
#endif
