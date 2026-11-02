#if !APPSTORE
import AppKit
import SwiftUI

/// Under the island, while a volume or brightness key is pressed: the same capsule as the
/// line that tells how the Mac is doing (VitalsHoverLine), a coloured dot and a short text.
struct SystemLevelLine: View {
    let islandW: CGFloat
    let islandH: CGFloat
    @ObservedObject private var model = SystemHUDController.shared.model

    var body: some View {
        ZStack {
            if model.visible {
                HStack(spacing: 6) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 6, height: 6)
                    Text(verbatim: text)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundColor(Color(hex: "#E1E3E6"))
                        .lineLimit(1)
                        .fixedSize()
                        .contentTransition(.numericText())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.black.opacity(0.92)))
                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
                .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.visible)
        .animation(.easeOut(duration: 0.15), value: model.level)
        .position(x: islandW / 2, y: islandH + 18)
        .allowsHitTesting(false)
    }

    private var text: String {
        if model.target == .volume && model.muted {
            return String(localized: "system-hud.line.muted")
        }
        let name: String
        switch model.target {
        case .volume:   name = String(localized: "system-hud.line.volume")
        case .display:  name = String(localized: "system-hud.line.display")
        case .keyboard: name = String(localized: "system-hud.line.keyboard")
        }
        let percent = Double(SystemHUDLogic.percent(level: model.level, muted: false)) / 100
        return "\(name) \(percent.formatted(.percent.precision(.fractionLength(0))))"
    }

    /// The vitals line's palette: one colour per kind of key, grey when muted.
    private var dotColor: Color {
        if model.target == .volume && model.muted { return Color(hex: "#8E939C") }
        switch model.target {
        case .volume:   return Color(hex: "#3B9EFF")
        case .display:  return Color(hex: "#F5A524")
        case .keyboard: return Color(hex: "#A78BFA")
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
