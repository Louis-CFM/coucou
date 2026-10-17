#if !APPSTORE
import SwiftUI

struct YouTubePill: View {
    let task: AgentTask
    @Binding var swapping: Bool
    let onTap: () -> Void
    @ObservedObject private var controller = YouTubeController.shared
    @State private var hovered = false

    var body: some View {
        ZStack {
            Capsule().fill(Color(hex: hovered ? "#301018" : "#0E0F11"))
            Capsule().stroke(Color(hex: YouTubeController.color).opacity(hovered ? 0.6 : 0.18), lineWidth: 1)
            HStack(spacing: 6) {
                Image(systemName: "play.rectangle.fill")
                    .foregroundStyle(Color(hex: YouTubeController.color))
                Text(controller.title ?? String(localized: "YouTube"))
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if hovered && controller.title != nil {
                    Button { controller.togglePlayback() } label: {
                        Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    }.buttonStyle(.plain)
                    Button { controller.nextVideo() } label: {
                        Image(systemName: "forward.fill")
                    }.buttonStyle(.plain)
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color(hex: "#F5F6F8"))
            .padding(.horizontal, 9)
            .contentShape(Capsule())
            .onTapGesture(perform: onTap)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .onHover { value in
            guard !swapping else { return }
            withAnimation(.easeOut(duration: 0.15)) { hovered = value }
        }
    }
}

struct YouTubeCardView: View {
    @ObservedObject private var controller = YouTubeController.shared
    private let red = Color(hex: YouTubeController.color)

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Circle().fill(controller.automationDenied ? Color(hex: "#F4505E") : red).frame(width: 7, height: 7)
                Text("YouTube").font(.system(size: 12, weight: .semibold))
                Text(controller.browserName ?? String(localized: "Safari / Chrome")).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
            }
            if let title = controller.title {
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                HStack(spacing: 14) {
                    Button { controller.previousVideo() } label: { Image(systemName: "backward.end.fill") }
                        .frame(width: 40, height: 36)
                        .contentShape(Rectangle())
                    Button { controller.togglePlayback() } label: {
                        Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    }
                        .frame(width: 40, height: 36)
                        .contentShape(Rectangle())
                    Button { controller.nextVideo() } label: { Image(systemName: "forward.end.fill") }
                        .frame(width: 40, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(red)
            } else if controller.automationDenied {
                Text(String(localized: "Allow Coucou to control Safari or Chrome in System Settings → Privacy & Security → Automation."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if controller.browserScriptingUnavailable {
                Text(String(localized: "Enable JavaScript from Apple Events in Safari or Chrome settings."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(String(localized: "Play a YouTube video in Safari or Chrome to show it here."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 108)
        .padding(.trailing, 22)
        .padding(.vertical, 7)
    }
}

/// Compact transport controls shown inside the resting notch while a YouTube
/// tab is available. The full card remains available when the island expands.
struct YouTubeCompactControls: View {
    @ObservedObject private var controller = YouTubeController.shared
    private let red = Color(hex: YouTubeController.color)

    var body: some View {
        if controller.url != nil {
            HStack(spacing: 0) {
                control("backward.end.fill", label: String(localized: "Previous video")) {
                    controller.previousVideo()
                }
                control(controller.isPlaying ? "pause.fill" : "play.fill",
                        label: controller.isPlaying ? String(localized: "Pause") : String(localized: "Play")) {
                    controller.togglePlayback()
                }
                control("forward.end.fill", label: String(localized: "Next video")) {
                    controller.nextVideo()
                }
            }
            .padding(.horizontal, 3)
            .frame(height: 22)
            .background(Capsule().fill(Color(hex: "#17181B")))
            .overlay(Capsule().stroke(red.opacity(0.35), lineWidth: 0.7))
            .help(controller.title ?? String(localized: "YouTube"))
        }
    }

    private func control(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(red)
                .frame(width: 18, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
#endif
