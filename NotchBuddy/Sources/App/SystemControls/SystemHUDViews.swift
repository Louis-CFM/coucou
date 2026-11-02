#if !APPSTORE
import AppKit
import SwiftUI

/// The volume / brightness card (IslandView.level): the upload card's look, a track in the
/// key's colour, and the island's own Mochi riding it at the level (BotPlacement puts him
/// there, like during an upload). The name of the level on the left, its value on the right.
struct SystemLevelCard: View {
    @ObservedObject private var model = SystemHUDController.shared.model

    // Content coordinates (the island's content has 10 pt of padding on each side and starts
    // under the 42 pt header): the track sits where SystemLevelLayout puts Mochi.
    private let trackLeft = SystemLevelLayout.trackLeft - 10
    private let trackWidth = SystemLevelLayout.trackWidth
    private let trackTop: CGFloat = 42

    /// Mochi's spring (BotPlacement), so the fill and Mochi move together.
    private static let spring = Animation.spring(response: 0.5, dampingFraction: 0.72)

    var body: some View {
        let colors = palette
        let level = CGFloat(min(max(model.level, 0), 1))
        let fillWidth = trackWidth * level

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(hex: "#141518"))

            // The key's colour washing up from the bottom, brighter with the level.
            RoundedRectangle(cornerRadius: 20)
                .fill(RadialGradient(
                    colors: [colors.bright.opacity(0.08 + 0.14 * level), Color.clear],
                    center: UnitPoint(x: 0.5, y: 1.4),
                    startRadius: 0,
                    endRadius: 260
                ))

            RoundedRectangle(cornerRadius: 3)
                .fill(Color.white.opacity(0.09))
                .frame(width: trackWidth, height: 6)
                .offset(x: trackLeft, y: trackTop)

            RoundedRectangle(cornerRadius: 3)
                .fill(LinearGradient(colors: [colors.deep, colors.bright],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: fillWidth, height: 6)
                .offset(x: trackLeft, y: trackTop)

            // The glow trailing behind Mochi, as during an upload.
            if level > 0.01 {
                Ellipse()
                    .fill(colors.glow.opacity(0.45))
                    .frame(width: 28, height: 12)
                    .blur(radius: 5)
                    .offset(x: trackLeft + fillWidth - 14, y: trackTop - 3)
            }

            HStack(spacing: 0) {
                Text(verbatim: title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(Color(hex: "#A9ADB5"))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(verbatim: value)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(Color(hex: "#A9ADB5"))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .frame(width: trackWidth)
            .offset(x: trackLeft, y: trackTop - 28)

            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.035), lineWidth: 1)
        }
        .animation(Self.spring, value: model.level)
        .animation(.easeInOut(duration: 0.25), value: model.muted)
        .animation(.easeInOut(duration: 0.25), value: model.target)
    }

    private var title: String {
        switch model.target {
        case .volume:   return String(localized: "system-hud.line.volume")
        case .display:  return String(localized: "system-hud.line.display")
        case .keyboard: return String(localized: "system-hud.line.keyboard")
        }
    }

    private var value: String {
        if model.target == .volume && model.muted { return String(localized: "system-hud.line.muted") }
        let percent = Double(SystemHUDLogic.percent(level: model.level, muted: false)) / 100
        return percent.formatted(.percent.precision(.fractionLength(0)))
    }

    /// One colour per kind of key (the vitals line's palette), grey when muted.
    private var palette: (deep: Color, bright: Color, glow: Color) {
        if model.target == .volume && model.muted {
            return (Color(hex: "#4B5058"), Color(hex: "#8E939C"), Color(hex: "#B5B9C0"))
        }
        switch model.target {
        case .volume:   return (Color(hex: "#1F6FD1"), Color(hex: "#3B9EFF"), Color(hex: "#8CC4FF"))
        case .display:  return (Color(hex: "#D98A12"), Color(hex: "#F5A524"), Color(hex: "#FCD34D"))
        case .keyboard: return (Color(hex: "#7C5CFF"), Color(hex: "#A78BFA"), Color(hex: "#C4B5FD"))
        }
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
