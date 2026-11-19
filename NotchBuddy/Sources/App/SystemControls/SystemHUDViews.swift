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

    private var title: String { Self.title(for: model.target) }
    private var value: String { Self.value(level: model.level, muted: model.muted, target: model.target) }

    static func title(for target: SystemHUDTarget) -> String {
        switch target {
        case .volume:   return String(localized: "system-hud.line.volume")
        case .display:  return String(localized: "system-hud.line.display")
        case .keyboard: return String(localized: "system-hud.line.keyboard")
        }
    }

    static func value(level: Double, muted: Bool, target: SystemHUDTarget) -> String {
        if target == .volume && muted { return String(localized: "system-hud.line.muted") }
        let percent = Double(SystemHUDLogic.percent(level: level, muted: false)) / 100
        return percent.formatted(.percent.precision(.fractionLength(0)))
    }

    /// The key's colour (bright tone of the card's palette).
    static func color(for target: SystemHUDTarget) -> Color {
        switch target {
        case .volume:   return Color(hex: "#3B9EFF")
        case .display:  return Color(hex: "#F5A524")
        case .keyboard: return Color(hex: "#A78BFA")
        }
    }

    /// One colour per kind of key (the vitals line's palette), grey when muted.
    private var palette: (deep: Color, bright: Color, glow: Color) {
        if model.target == .volume && model.muted {
            return (Color(hex: "#4B5058"), Color(hex: "#8E939C"), Color(hex: "#B5B9C0"))
        }
        let bright = Self.color(for: model.target)
        switch model.target {
        case .volume:   return (Color(hex: "#1F6FD1"), bright, Color(hex: "#8CC4FF"))
        case .display:  return (Color(hex: "#D98A12"), bright, Color(hex: "#FCD34D"))
        case .keyboard: return (Color(hex: "#7C5CFF"), bright, Color(hex: "#C4B5FD"))
        }
    }
}

/// In the island's header, when a volume or brightness key is pressed while the island is
/// open on a view the level card can't replace (the chat, a mail, the voice, an upload): the
/// header pill Coucou uses for the Claude plan (ClaudePlanHeaderPill, in its active look),
/// with the key's colour, its icon, a small track and the value.
///
/// Kept about as wide as the plan pill: the room right of the notch, before the header's
/// icons, is narrow (Coucou shows a single plan pill there for that reason). A name instead
/// of the icon, or a longer track, slid its left end under the notch.
struct SystemLevelHeaderPill: View {
    @ObservedObject private var model = SystemHUDController.shared.model

    private static let trackWidth: CGFloat = 28

    var body: some View {
        ZStack {
            if model.lineVisible {
                let muted = model.target == .volume && model.muted
                let color = muted ? Color(hex: "#8E939C") : SystemLevelCard.color(for: model.target)
                let level = CGFloat(muted ? 0 : min(max(model.level, 0), 1))
                HStack(spacing: 5) {
                    Image(systemName: symbol(muted: muted))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(color.lighter(by: 0.3))
                        .frame(width: 12)
                        .contentTransition(.symbolEffect(.replace))
                    // The card's track, small.
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule()
                            .fill(color)
                            .frame(width: Self.trackWidth * level)
                    }
                    .frame(width: Self.trackWidth, height: 4)
                    if !muted {
                        Text(verbatim: SystemLevelCard.value(level: model.level, muted: false,
                                                             target: model.target))
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundColor(color.lighter(by: 0.3))
                            .lineLimit(1)
                            .fixedSize()
                            .contentTransition(.numericText())
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(color.opacity(0.18)))
                .overlay(Capsule().stroke(color.opacity(0.55), lineWidth: 1))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(SystemLevelCard.title(for: model.target) + " "
                                    + SystemLevelCard.value(level: model.level, muted: model.muted,
                                                            target: model.target))
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: model.lineVisible)
        .animation(.spring(response: 0.5, dampingFraction: 0.72), value: model.level)
        .allowsHitTesting(false)
    }

    /// The key's icon: the header's own speaker for the volume, the sun, the keyboard light.
    private func symbol(muted: Bool) -> String {
        switch model.target {
        case .volume:   return muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        case .display:  return "sun.max.fill"
        case .keyboard: return "light.max"
        }
    }
}

/// Settings → Volume & brightness: its own page in the Coucou window.
struct SystemHUDSettingsSection: View {
    @State private var on = SystemHUDController.isEnabled
    @State private var trusted = AXIsProcessTrusted()
    @State private var volume = SystemHUDController.isEnabled(.volume)
    @State private var sound = SystemHUDSound.isEnabled
    @State private var soundChoice = SystemHUDSound.choice
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
                    Toggle(String(localized: "system-hud.sound"), isOn: $sound)
                        .onChange(of: sound) { _, v in SystemHUDSound.setEnabled(v) }
                        .disabled(!volume)
                        .padding(.leading, 20)
                    // Picking one plays it, to compare them by ear.
                    Picker(String(localized: "Sound"), selection: $soundChoice) {
                        ForEach(SystemHUDSound.Choice.allCases) { choice in
                            Text(verbatim: choice.title).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .onChange(of: soundChoice) { _, v in SystemHUDSound.shared.choose(v) }
                    .disabled(!volume || !sound)
                    .padding(.leading, 20)
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
