#if !APPSTORE
import SwiftUI
import AppKit

// MARK: - Now playing pieces (Spotify and Apple Music cards, GitHub build only)

struct NowPlayingArtwork: View {
    let image: NSImage?
    let accent: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.06))
            if let image {
                GeometryReader { geometry in
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: max(0, geometry.size.width), height: max(0, geometry.size.height))
                        .clipped()
                }
                .transition(.opacity)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(accent.opacity(0.7))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
        .animation(.easeInOut(duration: 0.25), value: image)
        .contentShape(Rectangle())
    }
}

/// Thin bar with elapsed / remaining time; drag or click anywhere on it to seek.
struct NowPlayingProgress: View {
    let position: Double
    let duration: Double
    let accent: Color
    let canSeek: Bool
    let onSeek: (Double) -> Void

    @State private var dragFraction: Double?

    private var fraction: Double {
        if let dragFraction { return dragFraction }
        guard duration > 0 else { return 0 }
        return min(1, max(0, position / duration))
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(Self.format(fraction * duration))
                .frame(minWidth: 26, alignment: .trailing)
            NowPlayingBar(
                fraction: fraction, accent: accent, enabled: canSeek,
                onChange: { dragFraction = $0 },
                onCommit: { f in
                    onSeek(f * duration)
                    dragFraction = nil
                }
            )
            .frame(height: 10)
            Text(duration > 0 ? "-" + Self.format(max(0, duration - fraction * duration)) : "")
                .frame(minWidth: 28, alignment: .leading)
        }
        .font(.system(size: 9.5).monospacedDigit())
        .foregroundColor(Color(hex: "#6B7079"))
    }

    static func format(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct NowPlayingVolume: View {
    let volume: Int
    let accent: Color
    let onChange: (Int) -> Void

    private var icon: String {
        switch volume {
        case 0: return "speaker.slash.fill"
        case 1..<34: return "speaker.wave.1.fill"
        case 34..<67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundColor(Color(hex: "#6B7079"))
                .frame(width: 13, alignment: .trailing)
            NowPlayingBar(
                fraction: Double(volume) / 100, accent: accent, enabled: true,
                onChange: { onChange(Int(($0 * 100).rounded())) },
                onCommit: { onChange(Int(($0 * 100).rounded())) }
            )
            .frame(width: 44, height: 10)
        }
        .help(String(localized: "Volume \(volume)%"))
    }
}

/// Player slider: grey track, filled part turns green and grows a knob on hover.
struct NowPlayingBar: View {
    let fraction: Double
    let accent: Color
    let enabled: Bool
    let onChange: (Double) -> Void
    let onCommit: (Double) -> Void

    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let f = min(1, max(0, fraction))
            let active = enabled && (hovering || dragging)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: active ? 4 : 3)
                Capsule()
                    .fill(active ? accent : Color(hex: "#C5C8CD"))
                    .frame(width: w * f, height: active ? 4 : 3)
                if active {
                    Circle()
                        .fill(Color(hex: "#F5F6F8"))
                        .frame(width: 9, height: 9)
                        .shadow(color: .black.opacity(0.4), radius: 2)
                        .offset(x: min(w - 9, max(0, w * f - 4.5)))
                }
            }
            .frame(width: w, height: geo.size.height)
            .contentShape(Rectangle())
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard enabled else { return }
                        dragging = true
                        onChange(min(1, max(0, g.location.x / w)))
                    }
                    .onEnded { g in
                        guard enabled else { return }
                        dragging = false
                        onCommit(min(1, max(0, g.location.x / w)))
                    }
            )
        }
    }
}

struct NowPlayingIconButton: View {
    let icon: String
    let size: CGFloat
    let tint: Color
    let help: LocalizedStringKey
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(hovered ? tint.opacity(1).lighter(by: 0.2) : tint)
                .frame(width: 16, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(NowPlayingPressStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovered = h } }
        .help(help)
    }
}

// Expansion is inherited so all three independent players use the same presentation.
private struct MusicCardExpansionKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}
private struct MusicCardWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 322
}
extension EnvironmentValues {
    var musicCardWidth: CGFloat {
        get { self[MusicCardWidthKey.self] }
        set { self[MusicCardWidthKey.self] = newValue }
    }
    var musicCardExpansion: CGFloat {
        get { self[MusicCardExpansionKey.self] }
        set { self[MusicCardExpansionKey.self] = newValue }
    }
}

/// Trial layout: the same cover grows and travels to the trailing end, without replacement.
struct MusicArtworkExpansion: ViewModifier {
    @Environment(\.musicCardWidth) private var cardWidth
    let fraction: CGFloat
    func body(content: Content) -> some View {
        content
            .frame(width: 36 + 22 * fraction, height: 36 + 22 * fraction)
            .frame(width: 36, height: 36, alignment: .topLeading)
            .offset(x: max(0, cardWidth - 120 - 58) * fraction, y: 10 * fraction)
    }
}

/// Center transport on the progress row, keeping volume/power clear on the trailing edge.
/// Interpolated positions preserve the controls' identity while resizing.
struct MusicTransportLayout: Layout {
    var fraction: CGFloat
    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 200, height: 20)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let transport = subviews[0].sizeThatFits(.unspecified)
        let auxiliary = subviews[1].sizeThatFits(.unspecified)
        let available = max(0, bounds.width - auxiliary.width - 8 - transport.width)
        let centered = min(available, max(0, (bounds.width - transport.width) / 2))
        subviews[0].place(
            at: CGPoint(x: bounds.minX + centered * fraction, y: bounds.midY),
            anchor: .leading, proposal: ProposedViewSize(transport))
        subviews[1].place(
            at: CGPoint(x: bounds.maxX, y: bounds.midY),
            anchor: .trailing, proposal: ProposedViewSize(auxiliary))
    }
}

struct NowPlayingPressStyle: ButtonStyle {
    @Environment(\.musicCardExpansion) private var expansion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.9 + 0.06 * expansion : 1)
            .animation(
                reduceMotion
                    ? nil : (expansion == 0 ? .spring(response: 0.2, dampingFraction: 0.7) : .easeOut(duration: 0.14)),
                value: configuration.isPressed)
    }
}
#endif
