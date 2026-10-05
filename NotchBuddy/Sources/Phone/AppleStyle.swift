import SwiftUI

// The pieces that make Coucou feel like an Apple app: Liquid Glass on iOS 26
// (a frosted material before), the agent's color moving softly behind a
// session, Apple Pay's drawn checkmark, and symbols that move with the state.

extension View {
    /// A card in glass (iOS 26) or the dark material Coucou used before.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 22, tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            if let tint {
                glassEffect(.regular.tint(tint.opacity(0.25)), in: RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
            }
        } else {
            background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    /// A glass button (iOS 26), bordered before. Prominent buttons are filled with the tint.
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}

/// The agent's color, moving slowly like the background of Apple Music. Drawn
/// in code (MeshGradient), 10 frames a second, only while on screen.
struct AgentBackdrop: View {
    let hex: String

    private var colors: [Color] {
        let base = Color(hex: hex)
        return [base.opacity(0.75), base.opacity(0.45), base.opacity(0.65),
                base.opacity(0.35), Color.black.opacity(0.6), base.opacity(0.3),
                Color.black, Color.black, Color.black]
    }

    /// The middle points drift a little; the edges stay put.
    private static func points(at t: Float) -> [SIMD2<Float>] {
        let topX: Float = 0.5 + 0.1 * sin(t * 0.31)
        let leftY: Float = 0.5 + 0.08 * cos(t * 0.27)
        let midX: Float = 0.5 + 0.12 * cos(t * 0.23)
        let midY: Float = 0.45 + 0.1 * sin(t * 0.37)
        let rightY: Float = 0.5 + 0.08 * sin(t * 0.29)
        let bottomX: Float = 0.5 + 0.1 * cos(t * 0.33)
        return [
            SIMD2(0, 0), SIMD2(topX, 0), SIMD2(1, 0),
            SIMD2(0, leftY), SIMD2(midX, midY), SIMD2(1, rightY),
            SIMD2(0, 1), SIMD2(bottomX, 1), SIMD2(1, 1),
        ]
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 10)) { timeline in
            MeshGradient(width: 3, height: 3,
                         points: Self.points(at: Float(timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600))),
                         colors: colors)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Apple Pay's "Done": a green ring draws itself, then the checkmark.
struct DrawnCheckmark: View {
    var size: CGFloat = 56
    @State private var ring: CGFloat = 0
    @State private var tick: CGFloat = 0

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: ring)
                .stroke(Color.green, style: StrokeStyle(lineWidth: size * 0.07, lineCap: .round))
                .rotationEffect(.degrees(-90))
            CheckShape()
                .trim(from: 0, to: tick)
                .stroke(Color.green, style: StrokeStyle(lineWidth: size * 0.08, lineCap: .round, lineJoin: .round))
                .padding(size * 0.28)
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.easeOut(duration: 0.45)) { ring = 1 }
            withAnimation(.easeOut(duration: 0.3).delay(0.35)) { tick = 1 }
        }
    }

    private struct CheckShape: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - rect.height * 0.12))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.12))
            return path
        }
    }
}

/// A small symbol that moves with the session's state: it breathes while
/// waiting for you, pulses while working, wiggles on an error, bounces when done.
struct StateSymbol: View {
    let session: SessionItem

    var body: some View {
        switch session.urgency {
        case 0:
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                .symbolEffect(.breathe)
        case 1:
            Image(systemName: "questionmark.bubble.fill").foregroundStyle(.cyan)
                .symbolEffect(.breathe)
        case 2:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                .symbolEffect(.wiggle, options: .repeat(2), value: session.updatedAt)
        case 3:
            Image(systemName: "ellipsis").foregroundStyle(.secondary)
                .symbolEffect(.variableColor.iterative)
        case 4:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                .symbolEffect(.bounce, value: session.updatedAt)
        default:
            Image(systemName: "moon.zzz.fill").foregroundStyle(.tertiary)
        }
    }
}
