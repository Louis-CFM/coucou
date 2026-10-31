import SwiftUI

/// Top-level SwiftUI view rendered inside the 720×320 transparent panel.
/// The island is drawn at the top-center; everything else is transparent and click-through.
/// Note: drag-drop is handled at the AppKit level in IslandWindowController (FileDropNSView),
/// not in SwiftUI, to avoid interfering with SwiftUI hit-testing.
struct IslandRootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let placement = state.islandPlacement
        ZStack(alignment: placement.alignment) {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if placement.isCorner {
                // Held by its corner: it grows away from it (IslandPlacement.islandRect).
                IslandContainer(state: state)
                    .padding(.horizontal, IslandPlacement.side)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: placement.alignment)
                // Mochi over it, in a box fixed at the same corner of the panel: nothing around
                // him moves while the island grows, so he only follows his own spring (inside the
                // growing island, its frame and his box were each rounded to the pixel on their
                // own and he shook on his way).
                CornerBot(state: state)
                    .padding(.horizontal, IslandPlacement.side)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: placement.alignment)
            } else {
                IslandContainer(state: state)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .ignoresSafeArea()
    }
}

/// Mochi when the island lives in a corner: in a box held by the panel's corner (no animated
/// frame around him), placed from the island's final size like BotPlacement does inside it.
struct CornerBot: View {
    @ObservedObject var state: AppState

    var body: some View {
        let p = state.islandPlacement
        let upload = UploadSequenceEngine.shared
        let box: CGFloat = 300
        let (w, fixedH) = islandSize(mode: state.mode, view: state.view, progress: state.uploadProgress,
                                     nw: state.notchWidth, nh: state.notchHeight)
        // The chat grows with the conversation (IslandContainer.chatPromptHeight).
        let h = state.mode == .expanded && state.view == .prompt
            ? min(300, 240 + CGFloat(state.chatHistory.count) * 40) : fixedH
        let hidden = state.mode == .expanded && (state.view == .greeting
            || (upload.isActive && [.upload, .uploading, .choose].contains(state.view)))
        BotPlacement(state: state, islandW: w, islandH: h,
                     shift: CGSize(width: p.isRight ? w - box : 0, height: p.isBottom ? h - box : 0),
                     damping: 0.92)
            .frame(width: box, height: box)
            .opacity(hidden ? 0 : 1)
            .animation(.easeInOut(duration: 0.25), value: hidden)
            .allowsHitTesting(false)
    }
}

extension IslandPlacement {
    /// The panel corner the island is held by (top centre at the notch).
    var alignment: Alignment {
        switch self {
        case .notch:       return .top
        case .topLeft:     return .topLeading
        case .topRight:    return .topTrailing
        case .bottomLeft:  return .bottomLeading
        case .bottomRight: return .bottomTrailing
        }
    }
}

// MARK: - Island container

struct IslandContainer: View {
    @ObservedObject var state: AppState
    @ObservedObject private var demoEngine = DemoEngine.shared
    @State private var islandWidth:  CGFloat = IslandConst.notchWidth
    @State private var islandHeight: CGFloat = IslandConst.notchHeight
    @State private var cornerRadius: CGFloat = IslandConst.roundedCorner
    // topRadius > 0 → convex expanded corners; < 0 → concave ear cutouts
    @State private var islandTopRadius: CGFloat = 0
    @State private var greetNotif: Bool = false

    private let openSpring = Animation.spring(response: 0.5, dampingFraction: 0.72)
    private let closeEase  = Animation.timingCurve(0.45, 0, 0.2, 1, duration: 0.34)

    private var chatPromptHeight: CGFloat {
        let base: CGFloat = 240
        let perMsg: CGFloat = 40
        return min(300, base + CGFloat(state.chatHistory.count) * perMsg)
    }

    /// Pixels the content must be pushed down to clear the concave ear transparent area.
    /// = 0 in expanded mode (no ears), = earRadius in compact/notch mode.
    private var earOffset: CGFloat { max(0, -islandTopRadius) }

    var body: some View {
        // Canvas active during drag-over (.upload), post-drop animation (.uploading),
        // AND choose overlay (.choose) — canvas handles the full sequence through user action.
        // Engine deactivates when user clicks a canvas choose button or navigates away.
        let uploadActive = state.mode == .expanded
            && UploadSequenceEngine.shared.isActive
            && (state.view == .upload || state.view == .uploading || state.view == .choose)

        let greetingActive = state.mode == .expanded && state.view == .greeting

        return ZStack(alignment: .topLeading) {
            // Black island shape
            IslandShape(width: islandWidth, height: islandHeight,
                        cornerRadius: cornerRadius, topRadius: islandTopRadius)
                // Hidden over a real notch: draw nothing. A black copy of the notch would slide
                // away with the Space on a desktop swipe, while the real notch stays.
                .fill(Color.black.opacity(state.mode == .hidden && state.hasNotch ? 0 : 1))
                // Floating in a corner: a thin edge and a shadow lift it off the desktop.
                .overlay(
                    IslandShape(width: islandWidth, height: islandHeight,
                                cornerRadius: cornerRadius, topRadius: islandTopRadius)
                        .stroke(Color.white.opacity(state.islandPlacement.isCorner ? 0.09 : 0), lineWidth: 1)
                )
                .shadow(color: .black.opacity(state.islandPlacement.isCorner ? 0.45 : 0), radius: 14, y: 6)

            // Content
            if state.mode == .expanded {
                if greetingActive {
                    // Greeting canvas: fixed 640-wide, centered by offset so x=320 aligns with island center
                    GreetingCanvasView(state: state)
                        .frame(width: IslandConst.expandedWidth, height: 150)
                        .offset(x: (islandWidth - IslandConst.expandedWidth) / 2)
                        .clipShape(IslandShape(width: islandWidth, height: islandHeight,
                                              cornerRadius: cornerRadius, topRadius: islandTopRadius))
                        .transition(.opacity)
                } else if uploadActive {
                    ZStack(alignment: .topLeading) {
                        UploadCanvasView(state: state)
                            .frame(width: islandWidth, height: islandHeight)
                            .clipShape(IslandShape(width: islandWidth, height: islandHeight,
                                                  cornerRadius: cornerRadius, topRadius: islandTopRadius))
                        // Header overlaid: canvas CARD_Y=42 aligns exactly with header bottom,
                        // matching normal view proportions (8pt top + 34pt header + card + 10pt bottom).
                        IslandHeader(state: state)
                            .frame(width: islandWidth, height: 34)
                            .offset(y: 8)
                    }
                    .transition(.opacity)
                } else {
                    IslandContentView(state: state)
                        .frame(width: islandWidth, height: islandHeight - earOffset)
                        .offset(y: earOffset)
                        .clipShape(IslandShape(width: islandWidth, height: islandHeight,
                                              cornerRadius: cornerRadius, topRadius: islandTopRadius))
                        // In a corner, held by it while the island grows (no slide).
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: state.islandPlacement.isCorner ? state.islandPlacement.alignment : .topLeading)
                        .transition(.opacity)
                }
            }

            // Compact in a corner, the pointer on it: the other pills come out of the tile.
            if state.mode == .compact && state.islandPlacement.isCorner && state.cornerPeek {
                CornerBubbles(state: state)
                    .frame(width: islandWidth, height: islandHeight)
                    .transition(.opacity)
            }

            // Open in a corner: the other pills' Mochis on a quarter circle around Mochi.
            if state.mode == .expanded && state.view == .overview && state.islandPlacement.isCorner
                && !uploadActive && !greetingActive {
                CornerArcView(state: state, islandW: islandWidth, islandH: islandHeight)
                    // Held by the island's corner while it grows.
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: state.islandPlacement.alignment)
                    .transition(.opacity)
            }

            // Single BotPlacement — always alive in the view tree so spring animations
            // fire from the current position (e.g. choose at 60,101) when canvas deactivates.
            // Hidden during upload canvas or greeting (both draw their own Mochi).
            // In a corner, Mochi is drawn by IslandRootView (CornerBot), over the island.
            if !state.islandPlacement.isCorner {
            BotPlacement(state: state, islandW: islandWidth, islandH: islandHeight)
                // Keep idle animations inside the resting strip. Expanded views
                // retain the panel's full height for particles and hands.
                .mask(alignment: .topLeading) {
                    Rectangle().frame(width: islandWidth,
                                      height: state.mode == .expanded ? 320 : islandHeight)
                }
                .opacity(uploadActive || greetingActive ? 0 : 1)
                .animation(.easeInOut(duration: 0.25), value: uploadActive || greetingActive)
            }

            CountdownBar(state: state, islandW: islandWidth)

            // Under the island while the pointer is on Mochi: how the Mac is doing.
            VitalsHoverLine(islandW: islandWidth, islandH: islandHeight)

            if demoEngine.isActive {
                Text(verbatim: "DEMO")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(.black)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color(hex: "#4ADE80"))
                    .clipShape(Capsule())
                    .position(x: 18, y: islandHeight - 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: demoEngine.isActive)
            }

            Group {
                // In a corner the tile holds Mochi alone: no room for the mini Mochis.
                if state.mode == .compact && !state.islandPlacement.isCorner {
                    CompactMiniGrid(state: state)
                        .scaleEffect(IslandRestingLayout(width: islandWidth, height: islandHeight).miniGridScale)
                        .position(x: islandWidth - 40, y: islandHeight / 2)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: state.mode == .compact)
        }
        .frame(width: islandWidth, height: islandHeight, alignment: .topLeading)
        .onChange(of: state.mode) { oldMode, newMode in
            let shrinking = modeOrder(newMode) < modeOrder(oldMode)
            let anim = shrinking ? closeEase : openSpring
            let (w, h) = islandSize(mode: newMode, view: state.view,
                                    progress: state.uploadProgress,
                                    nw: state.notchWidth, nh: state.notchHeight)
            let cr  = islandCorner(newMode)
            // In a corner the island floats: its top corners are rounded too.
            let tr: CGFloat = state.islandPlacement.isCorner ? cr : 0
            withAnimation(anim) {
                islandWidth      = w
                islandHeight     = (newMode == .expanded && state.view == .prompt) ? chatPromptHeight : h
                cornerRadius     = cr
                islandTopRadius  = tr
            }
        }
        .onChange(of: state.view) { _, newView in
            guard state.mode == .expanded else { return }
            // Deactivate engine if user navigates outside the upload flow
            let uploadViews: Set<IslandView> = [.upload, .uploading, .choose]
            if UploadSequenceEngine.shared.isActive && !uploadViews.contains(newView) {
                UploadSequenceEngine.shared.deactivate()
            }
            let (w, h) = islandSize(mode: .expanded, view: newView,
                                    progress: state.uploadProgress,
                                    nw: state.notchWidth, nh: state.notchHeight)
            withAnimation(openSpring) {
                islandWidth  = w
                islandHeight = newView == .prompt ? chatPromptHeight : h
            }
        }
        .onChange(of: state.chatHistory.count) { _, _ in
            guard state.mode == .expanded, state.view == .prompt else { return }
            withAnimation(openSpring) { islandHeight = chatPromptHeight }
        }
        .onAppear {
            let (w, h) = islandSize(mode: state.mode, view: state.view,
                                    progress: state.uploadProgress,
                                    nw: state.notchWidth, nh: state.notchHeight)
            islandWidth      = w
            islandHeight     = state.view == .prompt ? chatPromptHeight : h
            cornerRadius     = islandCorner(state.mode)
            islandTopRadius  = state.islandPlacement.isCorner ? cornerRadius : 0
        }
        .onReceive(NotificationCenter.default.publisher(for: .islandResize)) { _ in
            guard state.mode == .expanded, state.view != .prompt else { return }
            let (w, h) = islandSize(mode: .expanded, view: state.view,
                                    progress: state.uploadProgress,
                                    nw: state.notchWidth, nh: state.notchHeight)
            withAnimation(openSpring) {
                islandWidth  = w
                islandHeight = h
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .botGreet)) { _ in
            greetNotif.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .islandScreenChanged)) { _ in
            // New screen, new resting size (notch ↔ bar): snap without animation.
            let (w, h) = islandSize(mode: state.mode, view: state.view,
                                    progress: state.uploadProgress,
                                    nw: state.notchWidth, nh: state.notchHeight)
            islandWidth  = w
            islandHeight = (state.mode == .expanded && state.view == .prompt) ? chatPromptHeight : h
            // The notch ↔ a corner: flat or rounded top, a round tile at rest.
            cornerRadius = islandCorner(state.mode)
            islandTopRadius = state.islandPlacement.isCorner ? cornerRadius : 0
        }
    }

    /// The island's corner radius: in a screen corner, resting or compact, a round tile.
    private func islandCorner(_ mode: IslandMode) -> CGFloat {
        if mode == .expanded { return IslandConst.expandedCorner }
        return state.islandPlacement.isCorner ? IslandPlacement.tileCorner : IslandConst.roundedCorner
    }

    private func modeOrder(_ m: IslandMode) -> Int {
        switch m { case .hidden: return 0; case .compact: return 1; case .expanded: return 2 }
    }
}

// MARK: - Island shape
//
// topRadius > 0  → convex rounded top corners (expanded mode)
// topRadius < 0  → concave ear cutouts, |topRadius| = ear radius (compact/notch mode)
// topRadius = 0  → sharp top corners (transient during animation)

struct IslandShape: Shape {
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat   // bottom corners
    var topRadius: CGFloat      // see above

    var animatableData: AnimatablePair<AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat>, CGFloat> {
        get { .init(.init(.init(width, height), cornerRadius), topRadius) }
        set {
            width        = newValue.first.first.first
            height       = newValue.first.first.second
            cornerRadius = newValue.first.second
            topRadius    = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let cr = max(0, cornerRadius)
        var p  = Path()

        if topRadius >= 0 {
            // ── Convex rounded top corners (expanded) ──────────────────────────
            let tr = min(topRadius, min(width / 2, height / 2))
            p.move(to: CGPoint(x: tr, y: 0))
            p.addLine(to: CGPoint(x: width - tr, y: 0))
            // Top-right convex corner
            p.addArc(center: CGPoint(x: width - tr, y: tr), radius: tr,
                     startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
            // Right edge
            p.addLine(to: CGPoint(x: width, y: height - cr))
            // Bottom-right corner
            p.addArc(center: CGPoint(x: width - cr, y: height - cr), radius: cr,
                     startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            // Bottom edge
            p.addLine(to: CGPoint(x: cr, y: height))
            // Bottom-left corner
            p.addArc(center: CGPoint(x: cr, y: height - cr), radius: cr,
                     startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            // Left edge
            p.addLine(to: CGPoint(x: 0, y: tr))
            // Top-left convex corner
            p.addArc(center: CGPoint(x: tr, y: tr), radius: tr,
                     startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        } else {
            // ── Concave ear cutouts (compact / notch) ─────────────────────────
            let er = -topRadius   // positive ear radius
            p.move(to: CGPoint(x: 0, y: 0))
            // Top-left ear
            p.addArc(center: CGPoint(x: 0, y: er), radius: er,
                     startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
            // Top edge
            p.addLine(to: CGPoint(x: width - er, y: er))
            // Top-right ear
            p.addArc(center: CGPoint(x: width, y: er), radius: er,
                     startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            // Right edge
            p.addLine(to: CGPoint(x: width, y: height - cr))
            // Bottom-right corner
            p.addArc(center: CGPoint(x: width - cr, y: height - cr), radius: cr,
                     startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            // Bottom edge
            p.addLine(to: CGPoint(x: cr, y: height))
            // Bottom-left corner
            p.addArc(center: CGPoint(x: cr, y: height - cr), radius: cr,
                     startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            // Left edge back to top-left corner
            p.addLine(to: CGPoint(x: 0, y: 0))
        }

        p.closeSubpath()
        return p
    }
}

// MARK: - Bot placement helper

struct BotPlacement: View {
    @ObservedObject var state: AppState
    let islandW: CGFloat
    let islandH: CGFloat
    /// Drawn in a box held by the island's corner (corner placements): the island's
    /// coordinates minus this, so Mochi doesn't drift while the island grows from its corner.
    var shift: CGSize = .zero
    /// How he springs between his places (in a corner: no bounce, he goes straight there).
    var damping: Double = 0.72

    var body: some View {
        let (rawCx, rawCy, diameter, rawOpacity) = botPosition(mode: state.mode, view: state.view, islandW: islandW, islandH: islandH, uploadProgress: state.uploadProgress, hasNotch: state.hasNotch)
        let cx = rawCx - shift.width, cy = rawCy - shift.height
        // Swapping places in a corner: CornerArcView draws him on his way.
        let opacity = state.cornerSwapping ? 0 : rawOpacity
        let canvasSize = diameter / 0.6
        let overhang: CGFloat = 40
        let isUploading = state.view == .uploading

        Group {
            // No glow in uploading mode — the tiny dot doesn't need it
            if state.mode == .expanded && !isUploading {
                Circle()
                    .fill(RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: botGlowColor(state.effectiveState), location: 0),
                            .init(color: .clear, location: 0.62)
                        ]),
                        center: .center,
                        startRadius: 0,
                        endRadius: diameter * 1.1
                    ))
                    .frame(width: diameter * 2.2, height: diameter * 2.2)
                    .blur(radius: 6)
                    .opacity(botGlowOpacity(state.effectiveState))
                    .position(x: cx, y: cy)
                    // The same spring as Mochi: the halo stays on him while he moves.
                    .animation(.spring(response: 0.5, dampingFraction: damping), value: cx)
                    .animation(.spring(response: 0.5, dampingFraction: damping), value: cy)
                    .animation(.easeInOut(duration: 0.4), value: state.effectiveState)
            }

            // Uploading: no particle overhang (no hearts during upload), positioned directly at cy.
            // BotEngine cy = H/2 + 0 + oy*R + R*0.06 ≈ H/2 (body centered in canvas).
            // With .position(x:y:) placing the frame center at (uploadCx, cy), bot is at cy ✓.
            //
            // Normal: extra 40pt canvas at top for heart particles; position offset up by 20pt;
            // BotEngine compensates with cy = H/2 + particleOverhang/2 + oy*R + R*0.06.
            if isUploading {
                TimelineView(.animation) { tl in
                    let elapsed: Double = {
                        guard let start = state.uploadStartTime else { return 0 }
                        return tl.date.timeIntervalSince(start)
                    }()
                    let t = min(1.0, max(0, elapsed / state.uploadDuration))
                    // cx = 36 + 526*t: bot center at fill right edge (bar left=36, width=526)
                    let uploadCx = 36 + CGFloat(t * (2 - t)) * 526
                    BotCanvasView(state: state, particleOverhang: 0, paused: state.mochiOnDesktop)
                        .frame(width: canvasSize, height: canvasSize)
                        .opacity(state.isDraggingBot || state.mochiOnDesktop ? 0 : opacity)
                        .position(x: uploadCx, y: cy)
                }
                .transition(.scale(scale: 0.01, anchor: .center).combined(with: .opacity))
            } else {
                // Invisible while Mochi lives on the desktop: no drawing either.
                BotCanvasView(state: state, particleOverhang: overhang, paused: state.mochiOnDesktop)
                    .frame(width: canvasSize, height: canvasSize + overhang)
                    .opacity(state.isDraggingBot || state.mochiOnDesktop ? 0 : opacity)
                    .position(x: cx, y: cy - overhang / 2)
                    .animation(.spring(response: 0.5, dampingFraction: damping), value: cx)
                    .animation(.spring(response: 0.5, dampingFraction: damping), value: cy)
                    .animation(.spring(response: 0.5, dampingFraction: damping), value: canvasSize)
                    .transition(.scale(scale: 0.01, anchor: .center).combined(with: .opacity))
            }
        }
        // Branch switch (uploading ↔ normal) animates with a fast spring: uploading dot
        // scales out at bar-end while normal bot scales in at choose position.
        .animation(.spring(response: 0.36, dampingFraction: 0.72), value: isUploading)
        // Slap, drag, and hover are handled by the AppKit NSEvent monitor in
        // IslandWindowController — not SwiftUI gestures — so this is safe.
        .allowsHitTesting(false)
    }

    private func botGlowColor(_ s: BotState) -> Color {
        switch s {
        case .working:   return Color(hex: "#3B9EFF")
        case .thinking:  return Color(hex: "#A78BFA")
        case .searching: return Color(hex: "#6366F1")
        case .approval:  return Color(hex: "#F5A524")
        case .error:     return Color(hex: "#F4505E")
        case .finished:  return Color(hex: "#34D399")
        case .ratelimit: return Color(hex: "#F59E0B")
        default:         return Color.white
        }
    }

    private func botGlowOpacity(_ s: BotState) -> Double {
        switch s {
        case .idle, .sleeping: return 0.15
        case .dizzy:           return 0.0
        default:               return 0.65
        }
    }
}

func botPosition(mode: IslandMode, view: IslandView, islandW: CGFloat, islandH: CGFloat, uploadProgress: Double, hasNotch: Bool = true) -> (CGFloat, CGFloat, CGFloat, Double) {
    let resting = IslandRestingLayout(width: islandW, height: islandH)
    let placement = IslandPlacement.current
    if placement.isCorner {
        switch mode {
        // The corner tile: Mochi alone, big, in its middle.
        case .hidden, .compact:
            // Measured from the island's corner, not its middle: right after a mode change the
            // size is still the open one, and the middle of that would send him across it.
            let t = IslandPlacement.tile
            return (placement.isRight ? islandW - t / 2 : t / 2,
                    (placement.isBottom ? islandH - t / 2 : t / 2) - 2,
                    min(38, max(0, t - 22)), 1)
        case .expanded where view == .overview:
            // Open: Mochi in the island's corner, the other pills around him (CornerArcView).
            let c = placement.cornerBotCenter(in: CGSize(width: islandW, height: islandH))
            return (c.x, c.y, 58, 1)
        default: break
        }
    }
    switch mode {
    case .hidden:
        return hasNotch ? (46, 16, 6, 0)
            : (islandW / 2, resting.botCenterY, resting.botDiameter, 1)
    case .compact: return (40, resting.botCenterY, resting.botDiameter, 1)
    case .expanded:
        let layout = IslandConst.viewLayouts[view]!
        let diameter = layout.botDiameter
        // Uploading: Mochi dot rides the leading edge of the progress fill.
        // Bar in island coords: left=36, width=526. cx = 36 + progress*526 (dot center at fill right edge).
        // cy comes from ViewLayout.botY (bar center in island coords).
        if view == .uploading {
            let cx = 36 + CGFloat(uploadProgress) * 526
            return (cx, layout.botY ?? 103, diameter, 1)
        }
        let cx = layout.botX
        let cy: CGFloat
        if let fixedY = layout.botY {
            cy = fixedY
        } else {
            // Center of the fixed 84pt card (VStack top=8, header=34 → content starts at y=42)
            let headerBottom: CGFloat = 42
            let cardH: CGFloat = 84
            cy = headerBottom + (islandH - headerBottom - cardH) / 2 + cardH / 2
        }
        return (cx, cy, diameter, 1)
    }
}

// MARK: - Active island view

private struct IslandViewActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False inside the island views that are mounted but not shown (opacity 0):
    /// TimelineViews in them pause. True everywhere else.
    var islandViewActive: Bool {
        get { self[IslandViewActiveKey.self] }
        set { self[IslandViewActiveKey.self] = newValue }
    }
}

// MARK: - Countdown bar

struct CountdownBar: View {
    @ObservedObject var state: AppState
    let islandW: CGFloat
    @State private var barWidth: CGFloat = 0
    @State private var timer: Timer? = nil

    var body: some View {
        GeometryReader { _ in
            Rectangle()
                .fill(Color.white.opacity(0.35))
                .frame(width: barWidth, height: 2)
                .cornerRadius(2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        // The bar only exists in the open island: its 10 Hz timer runs only then
        // (CLAUDE.md: 0 % CPU when the island is hidden).
        .onAppear { if state.mode == .expanded { startTimer() } }
        .onChange(of: state.mode) { _, mode in
            if mode == .expanded { startTimer() } else { stopTimer() }
        }
        .onDisappear { stopTimer() }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { updateBar() }
        }
        t.tolerance = 0.02
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        if barWidth != 0 { barWidth = 0 }
    }

    private func updateBar() {
        guard state.mode == .expanded && !state.isPinned else {
            if barWidth != 0 { barWidth = 0 }
            return
        }
        let autoClose = state.autoCloseInterval
        let window = min(10.0, autoClose * 0.6)
        let elapsed = Date.now.timeIntervalSince(state.lastActivity)
        let remaining = autoClose - elapsed
        let target: CGFloat = remaining < window ? max(0, CGFloat(remaining / window) * 160) : 0
        // The timer ticks at 10 Hz; a linear animation over the same 0.1 s glides between ticks,
        // so the bar shrinks on every display frame instead of in 10 steps a second.
        if target < barWidth && barWidth - target < 40 {
            withAnimation(.linear(duration: 0.1)) { barWidth = target }
        } else if target != barWidth {
            barWidth = target
        }
    }
}

// MARK: - Island content (header + views, only in expanded mode)

struct IslandContentView: View {
    @ObservedObject var state: AppState
    /// A mail open in the Mail card: the home view grows by this much, downwards only
    /// (the header and the pills stay where they are).
    @State private var mailExtra: CGFloat = 0

    var body: some View {
        let placement = state.islandPlacement
        // Home open in a top corner: Mochi and his circle take the corner, the header the rest.
        let cornerHome = placement.isCorner && state.view == .overview
        let headerGap: CGFloat = cornerHome ? IslandPlacement.cornerColumn : 0
        VStack(spacing: 0) {
            IslandHeader(state: state)
                .frame(height: 34)
                .padding(.leading, placement.isLeft ? headerGap : 0)
                .padding(.trailing, placement.isRight ? headerGap : 0)
                .opacity(state.view == .confused ? 0 : 1)
                .animation(.easeInOut(duration: 0.2), value: state.view == .confused)

            ZStack {
                ForEach(IslandView.allCases, id: \.self) { v in
                    let active = state.view == v
                    // Views that fill available height instead of the fixed 98pt content frame:
                    // chat (prompt) is always flexible; mail is flexible only when active so
                    // it doesn't push the ZStack taller when inactive.
                    let isTall = v == .prompt || ((v == .mail || v == .whatsNew) && active)
                        || (v == .overview && active && cornerHome)
                    let anim: Animation = active
                        ? .spring(response: 0.4, dampingFraction: 0.8).delay(0.16)
                        : .easeIn(duration: 0.16)
                    IslandViewContent(view: v, state: state)
                        // Views behind the active one stay mounted (for the cross-fade)
                        // but stop their endless animations: nobody sees them.
                        .environment(\.islandViewActive, active)
                        .frame(maxWidth: .infinity)
                        .frame(height: isTall ? nil : (v == .overview ? 98 + (placement.isCorner ? 0 : mailExtra) : 98),
                               alignment: v == .overview ? .top : .center)
                        .frame(minHeight: (isTall && !active) ? 0 : nil, maxHeight: isTall ? .infinity : nil)
                        .opacity(active ? 1 : 0)
                        .scaleEffect(active ? 1 : 0.97)
                        .allowsHitTesting(active)
                        .animation(anim, value: state.view)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 10)
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
        .foregroundColor(Color(hex: "#F5F6F8"))
        .onReceive(NotificationCenter.default.publisher(for: .islandResize)) { _ in
            let extra = max(0, (MailLayout.detailHeight ?? 160) - 160)
            // The island's own spring (IslandContainer.openSpring): the card and the island move together.
            withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { mailExtra = extra }
        }
    }
}

// MARK: - Island header (tabs + icons)

struct IslandHeader: View {
    @ObservedObject var state: AppState
    @State private var gearHovered  = false
    @State private var soundHovered = false
    @State private var closeHovered = false

    /// Pending approval or mail draft: the island refuses to fold (fsm.isHeldOpen), so the
    /// close cross is not shown.
    private var heldOpen: Bool { state.pendingApproval != nil || state.voiceMailDraft != nil }

    var body: some View {
        HStack(spacing: 0) {
            // Left: tab capsules
            HStack(spacing: 5) {
                TabButton(icon: "house.fill", view: .overview, state: state)
                TabButton(icon: "bubble.left.fill", view: .prompt, state: state, preAction: {
                    #if !APPSTORE
                    if state.promptContext == nil {
                        state.promptContext = WindowContextCapture.captureActive(from: state.lastExternalApp)
                    }
                    #endif
                })
                TabButton(icon: "plus", view: .upload, state: state)
            }
            .padding(.leading, 14)

            Spacer()

            // Right: plan pill (GitHub build, home view only) + action icons
            HStack(spacing: 8) {
                #if !APPSTORE
                // Claude and Codex both on: only Claude here (two pills and the icons do not
                // clear the notch); Codex is a row in the Claude plan card.
                if state.view == .overview && state.showPlanInNotch && state.planRelayInstalled {
                    ClaudePlanHeaderPill(state: state)
                } else if state.view == .overview && state.showCodexPlanInNotch {
                    ClaudePlanHeaderPill(state: state, codex: true)
                }
                #endif
                HStack(spacing: 14) {
                    Button(action: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            state.view = .settings
                        }
                    }) {
                        Image(systemName: state.view == .settings ? "gearshape.fill" : "gearshape")
                            .font(.system(size: 14))
                            .foregroundColor(state.view == .settings || gearHovered ? Color(hex: "#F5F6F8") : Color(hex: "#8E939C"))
                    }
                    .buttonStyle(.plain)
                    .onHover { gearHovered = $0 }

                    Button(action: { state.soundEnabled.toggle() }) {
                        Image(systemName: state.soundEnabled ? "speaker.wave.2" : "speaker.slash")
                            .font(.system(size: 14))
                            .foregroundColor(soundHovered ? Color(hex: "#F5F6F8") : Color(hex: "#8E939C"))
                    }
                    .buttonStyle(.plain)
                    .onHover { soundHovered = $0 }

                    // Fold back to the compact island now, without waiting for the timer.
                    if !heldOpen {
                        Button(action: {
                            NotificationCenter.default.post(name: .islandCollapse, object: nil)
                        }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 14))
                                .foregroundColor(closeHovered ? Color(hex: "#F5F6F8") : Color(hex: "#8E939C"))
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "Close"))
                        .onHover { closeHovered = $0 }
                    }
                }
            }
            .padding(.trailing, 16)
        }
        .frame(maxHeight: .infinity)
    }
}

struct TabButton: View {
    let icon: String
    let view: IslandView
    @ObservedObject var state: AppState
    var preAction: (() -> Void)? = nil
    @State private var isHovered = false

    private var isOn: Bool {
        if view == .overview { return state.view == .overview || state.view == .empty }
        return state.view == view
    }

    var body: some View {
        Button(action: {
            preAction?()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                state.view = view
            }
        }) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(isOn ? Color(hex: "#F5F6F8") : (isHovered ? Color(hex: "#B0B5BE") : Color(hex: "#8E939C")))
                .frame(width: 30, height: 22)
                .background(
                    isOn ? Color(hex: "#1D1F23") :
                    isHovered ? Color.white.opacity(0.07) : Color.clear
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Claude Plan header pill (GitHub build only)

#if !APPSTORE
struct ClaudePlanHeaderPill: View {
    @ObservedObject var state: AppState
    var codex: Bool = false
    @State private var isHovered = false

    private var effectiveColor: String {
        if codex { return CodexPlanGauge.color(state.codexPlanUsage) }
        return ClaudePlanGauge.color(for: (state.demoPlanUsageOverride ?? state.claudePlanUsage).flatMap { ClaudePlanGauge.dominantPct($0) })
    }

    private var label: String {
        if codex { return CodexPlanGauge.pillLabel(state.codexPlanUsage) }
        guard let usage = state.demoPlanUsageOverride ?? state.claudePlanUsage,
              let pct = ClaudePlanGauge.dominantPct(usage) else { return "Claude —" }
        return "Claude \(Int(pct.rounded()))%"
    }

    private var isOpen: Bool { state.showingPlanDetail && state.planDetailIsCodex == codex }
    private var isActive: Bool { isOpen || isHovered }

    var body: some View {
        Button(action: {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                let open = isOpen
                state.planDetailIsCodex = codex
                state.showingPlanDetail = !open
            }
            if codex { state.refreshCodexPlanUsage() }
        }) {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color(hex: effectiveColor))
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(isActive
                                     ? Color(hex: effectiveColor).lighter(by: 0.3)
                                     : Color(hex: "#6B7079"))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isActive
                          ? Color(hex: effectiveColor).opacity(0.18)
                          : Color(hex: "#0E0F11"))
            )
            .overlay(
                Capsule()
                    .stroke(Color(hex: effectiveColor).opacity(isActive ? 0.55 : 0.14), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { isHovered = h }
        }
        .onAppear { if codex { state.refreshCodexPlanUsage() } }
    }
}
#endif

// MARK: - Compact mini mochi grid (2×2 to the right of the notch)

struct CompactMiniGrid: View {
    @ObservedObject var state: AppState

    var body: some View {
        let cols = [GridItem(.fixed(12), spacing: 4), GridItem(.fixed(12), spacing: 4)]
        LazyVGrid(columns: cols, spacing: 4) {
            ForEach(state.gridSlots, id: \.id) { slot in
                switch slot {
                case .pill(let id):
                    if let task = state.tasks.first(where: { $0.id == id }) {
                        MiniBotCanvasView(task: task)
                            .frame(width: 12 / 0.6, height: 12 / 0.6)
                            .frame(width: 12, height: 12, alignment: .center)
                    }
                case .waiting(let ids):
                    // More sessions wait than there are places: how many.
                    Text(verbatim: "+\(ids.count)")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(Color(hex: "#F5F6F8"))
                        .frame(width: 12, height: 12)
                }
            }
        }
        .frame(width: 28, height: 28)
    }
}
