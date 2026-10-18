import SwiftUI

// MARK: - How the Mac is doing (under the island)

/// A small line under the island while the pointer is on Mochi, when the Mac makes him react:
/// "CPU 94 % · node, Google Chrome", "Your Mac is hot", "Battery 14 %".
struct VitalsHoverLine: View {
    let islandW: CGFloat
    let islandH: CGFloat
    @ObservedObject private var vitals = MachineVitals.shared

    var body: some View {
        let show = vitals.hovered && vitals.summary != nil
        ZStack {
            if show, let text = vitals.summary {
                HStack(spacing: 6) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 6, height: 6)
                    Text(verbatim: text)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(hex: "#E1E3E6"))
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.black.opacity(0.92)))
                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
                .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: show)
        .position(x: islandW / 2, y: islandH + 18)
        .allowsHitTesting(false)
    }

    private var dotColor: Color {
        let m = vitals.mood
        if m.hot > 0 { return Color(hex: "#FF6B4A") }
        if m.busy > 0 { return Color(hex: "#3B9EFF") }
        if m.full > 0 { return Color(hex: "#A78BFA") }
        return Color(hex: "#F5A524")
    }
}
