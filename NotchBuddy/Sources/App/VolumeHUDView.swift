import SwiftUI

/// What the volume HUD shows; `bump` changes on every key press, so a press at the
/// top or bottom of the range (level unchanged) still makes the Mochis hop.
struct VolumeHUDState: Equatable {
    var level: Double   // 0…1
    var muted: Bool
    var bump: Int
}

/// The volume HUD grows out of the notch: a wing on each side (Mochi on the left,
/// the level on the right) and a row of ten mini Mochis under the notch.
enum VolumeHUDLayout {
    static let wing: CGFloat = 118
    static let rowHeight: CGFloat = 42
    static let sideInset: CGFloat = 22
    static let miniDiameter: CGFloat = 16

    static func size(nw: CGFloat, nh: CGFloat) -> (CGFloat, CGFloat) {
        (nw + wing * 2, nh + rowHeight)
    }

    /// Mochis lit for a level: any volume in a Mochi's tenth wakes it.
    static func litCount(_ hud: VolumeHUDState) -> Int {
        hud.muted ? 0 : min(10, max(0, Int((hud.level * 10 - 1e-6).rounded(.up))))
    }
}

/// The level as ten mini Mochis lit from the left in the pill palette; the rest
/// sleep. A thin line under them shows the exact level. Mochi himself is not
/// drawn here: BotPlacement keeps him in the left wing.
struct VolumeHUDView: View {
    let hud: VolumeHUDState
    let islandW: CGFloat
    let notchH: CGFloat

    /// Red → fuchsia, then white for the top tenth.
    private static let colors = Array(PillColors.palette.dropFirst()) + [PillColors.palette[0]]

    var body: some View {
        let lit = VolumeHUDLayout.litCount(hud)
        let inset = VolumeHUDLayout.sideInset
        let rowW = max(0, islandW - inset * 2)
        let cellW = rowW / 10
        let d = VolumeHUDLayout.miniDiameter
        // Body bottom 5 pt above the floor line; BotEngine draws the body 0.06 R below
        // the canvas centre.
        let floorY = notchH + 32
        let canvasY = floorY - 5 - d / 2 * 0.88 - d / 2 * 0.06

        ZStack(alignment: .topLeading) {
            HStack(spacing: 5) {
                Image(systemName: hud.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(hex: "#8E939C"))
                Group {
                    if hud.muted {
                        Text("Muted")
                    } else {
                        Text(verbatim: "\(Int((hud.level * 100).rounded()))%")
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(Color(hex: hud.muted ? "#8E939C" : "#F5F6F8"))
            }
            .frame(width: islandW - inset, height: notchH, alignment: .trailing)

            ForEach(0..<10, id: \.self) { i in
                VolumeMiniBot(color: Self.colors[i],
                              lit: i < lit,
                              hops: i == lit - 1 || lit == 10,
                              bump: hud.bump)
                    .frame(width: d / 0.6, height: d / 0.6)
                    .position(x: inset + cellW * (CGFloat(i) + 0.5), y: canvasY)
            }

            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(hud.muted ? Color(hex: "#454850") : Color.white.opacity(0.4))
                    .frame(width: rowW * CGFloat(min(1, max(0, hud.level))))
                    .animation(.easeOut(duration: 0.25), value: hud.level)
            }
            .frame(width: rowW, height: 2)
            .offset(x: inset, y: floorY)
        }
        .frame(width: islandW, alignment: .topLeading)
    }
}

/// One mini Mochi of the meter: awake in its colour when lit, asleep and dark when not.
struct VolumeMiniBot: View {
    let color: String
    let lit: Bool
    /// The last lit Mochi (all of them at the top): hops, wide-eyed and blushing, on each press.
    let hops: Bool
    let bump: Int
    @StateObject private var engine = VolumeMiniBot.makeEngine()

    private static func makeEngine() -> BotEngine {
        let e = BotEngine()
        e.isMini = true
        return e
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                engine.update(dt: min(0.05, now - engine.lastTime))
                engine.draw(context: context, size: size)
            }
        }
        .onAppear {
            applyLit(force: true)
            if hops { engine.volumeHop(eye: .wide) }
        }
        .onChange(of: lit) { _, _ in applyLit(force: false) }
        .onChange(of: bump) { _, _ in
            if hops { engine.volumeHop(eye: .wide) }
        }
    }

    private func applyLit(force: Bool) {
        engine.bodyColor = cgColorFromHex(lit ? color : "#1D1F23")
        engine.inkColor = lit ? nil : cgColorFromHex("#454850")
        if !lit {
            // A Mochi that just went dark sleeps, even mid-hop with happy eyes.
            engine.eyeOverride = nil
            engine.eyeOverrideUntil = 0
        }
        engine.setState(lit ? .idle : .sleeping, force: force)
    }
}
