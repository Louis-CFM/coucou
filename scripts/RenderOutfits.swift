// RenderOutfits.swift — standalone planche renderer for Mochi outfits
// Compile + run via: bash scripts/render-outfits.sh
// Output: /tmp/coucou-outfits.png

import Foundation
import SwiftUI
import AppKit

// MARK: - Stubs (substitutes for app-only types)

@MainActor
final class SoundEngine {
    static let shared = SoundEngine()
    var enabled: Bool = false
    func play(_ name: String) {}
}

extension Notification.Name {
    static let botDizzy          = Notification.Name("notchBuddy.botDizzy")
    static let botGreet          = Notification.Name("notchBuddy.botGreet")
    static let botBlink          = Notification.Name("notchBuddy.botBlink")
    static let botSetTgEs        = Notification.Name("notchBuddy.botSetTgEs")
    static let botGulp           = Notification.Name("notchBuddy.botGulp")
    static let botMorphTo        = Notification.Name("notchBuddy.botMorphTo")
    static let triggerEmote      = Notification.Name("notchBuddy.triggerEmote")
    static let triggerSlap       = Notification.Name("notchBuddy.triggerSlap")
    static let greetComplete     = Notification.Name("notchBuddy.greetComplete")
    static let greetingHover     = Notification.Name("notchBuddy.greetingHover")
    static let greetingInterrupt = Notification.Name("notchBuddy.greetingInterrupt")
    static let islandAction      = Notification.Name("notchBuddy.islandAction")
    static let islandCollapse    = Notification.Name("notchBuddy.islandCollapse")
    static let hookReveal        = Notification.Name("notchBuddy.hookReveal")
    static let musicReveal       = Notification.Name("notchBuddy.musicReveal")
    static let openFullSettings  = Notification.Name("notchBuddy.openFullSettings")
}

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let val = UInt64(h, radix: 16) ?? 0
        let r = Double((val >> 16) & 0xFF) / 255
        let g = Double((val >> 8)  & 0xFF) / 255
        let b = Double( val        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Cell view — one outfit at one pose

struct MochiCell: View {
    let outfit: Outfit
    let yaw: CGFloat
    let pitch: CGFloat
    let tilt: CGFloat
    let phys: (dx: CGFloat, dy: CGFloat)
    let cellSize: CGFloat
    var roll: CGFloat = 0
    var presence: CGFloat = 1

    var body: some View {
        Canvas { context, sz in
            let W = sz.width, H = sz.height
            // scale=0.62, R = W * 0.62 * 0.3
            let R  = W * 0.62 * 0.3
            let rx = R * 1.14
            let ry = R * 0.88
            let cx = W / 2
            let cy = H / 2 + R * 0.06
            let sx: CGFloat = 1, sy: CGFloat = 1
            let morph: CGFloat = 0

            let mH = MochiH(R: R, yaw: yaw, pitch: pitch, physDx: phys.dx, physDy: phys.dy, roll: roll)

            // 1. Behind-body outfit
            drawOutfitBehindStatic(
                context: context, outfit: outfit, H: mH,
                cx: cx, cy: cy, tilt: tilt, sx: sx, sy: sy,
                roll: roll, morph: morph, isMini: false, presence: presence
            )

            // 2. Body (replicate BotEngine.drawBody for idle / pumpkin state)
            var bCtx = context
            bCtx.translateBy(x: cx, y: cy)
            if tilt != 0 { bCtx.rotate(by: .radians(tilt)) }
            bCtx.scaleBy(x: sx, y: sy)
            let body = mochiOutfitPath(rx, ry)

            // Base gradient (pumpkin-aware)
            let pumpkin = outfit == .pumpkin
            let cTop: Color = pumpkin ? Color(hex: "#FFA94D") : Color(red: 0.929, green: 0.929, blue: 0.937)
            let cBot: Color = pumpkin ? Color(hex: "#E8590C") : Color(red: 0.769, green: 0.773, blue: 0.792)
            bCtx.fill(body, with: .linearGradient(
                Gradient(colors: [cTop, cBot]),
                startPoint: CGPoint(x: rx * 0.7, y: -ry * 0.85),
                endPoint:   CGPoint(x: -rx * 0.8, y: ry * 0.9)
            ))
            // Shadow rim
            bCtx.fill(body, with: .radialGradient(
                Gradient(stops: [
                    .init(color: .clear, location: 0.6),
                    .init(color: Color.black.opacity(0.2), location: 1)
                ]),
                center: .zero, startRadius: R * 0.15, endRadius: R * 1.25
            ))
            // Top-left highlight
            bCtx.fill(body, with: .radialGradient(
                Gradient(stops: [
                    .init(color: Color.white.opacity(0.55), location: 0),
                    .init(color: .clear, location: 1)
                ]),
                center: CGPoint(x: rx * 0.34, y: -ry * 0.46),
                startRadius: 0, endRadius: R * 0.42
            ))

            // 3. Eyes (clipped to body)
            var eyeBase = bCtx
            eyeBase.clip(to: body)
            let ink = Color(red: 0.102, green: 0.082, blue: 0.071)
            for f in mEyeFrames(mH) {
                guard f.visible else { continue }
                var eCtx = eyeBase
                eCtx.translateBy(x: f.x, y: f.y)
                eCtx.scaleBy(x: f.fx, y: f.fy)
                let hh = max(f.h, f.w * 0.3)
                var pill = Path()
                pill.addRoundedRect(
                    in: CGRect(x: -f.w / 2, y: -hh / 2, width: f.w, height: hh),
                    cornerSize: CGSize(width: min(f.w / 2, hh / 2), height: min(f.w / 2, hh / 2))
                )
                eCtx.fill(pill, with: .color(ink))
            }

            // 4. Front outfit
            drawOutfitFrontStatic(
                context: context, outfit: outfit, H: mH,
                cx: cx, cy: cy, tilt: tilt, sx: sx, sy: sy,
                roll: roll, morph: morph, isMini: false, presence: presence
            )
        }
        .frame(width: cellSize, height: cellSize)
    }
}

// MARK: - Grid view

// Outfit order matching sheet.html
private let targetOutfits: [Outfit] = [
    .none, .beanie, .santaHat, .partyHat, .crown, .witchHat,
    .sunglasses, .roundGlasses, .scarf, .pumpkin, .bow,
]

private struct PoseSpec {
    let label: String
    let yaw: CGFloat
    let pitch: CGFloat
    let tilt: CGFloat
    let phys: (dx: CGFloat, dy: CGFloat)
    let size: CGFloat
}

// Columns matching sheet.html cols array + small pill-preview column (W=190, scale=0.62; small=64)
private let poses: [PoseSpec] = [
    PoseSpec(label: "L",     yaw: -0.5,  pitch:  0,     tilt: 0,    phys: (0.6,  0),    size: 190),
    PoseSpec(label: "front", yaw:  0,    pitch:  0,     tilt: 0,    phys: (0,    0),    size: 190),
    PoseSpec(label: "R",     yaw:  0.5,  pitch:  0,     tilt: 0,    phys: (-0.6, 0),    size: 190),
    PoseSpec(label: "up",    yaw:  0.15, pitch:  0.4,   tilt: 0,    phys: (0,    0.4),  size: 190),
    PoseSpec(label: "down",  yaw: -0.2,  pitch: -0.5,   tilt: 0,    phys: (0,   -0.4),  size: 190),
    PoseSpec(label: "tilt",  yaw:  0.3,  pitch: -0.25,  tilt: 0.12, phys: (-0.3, 0),   size: 190),
    PoseSpec(label: "mini",  yaw:  0,    pitch:  0,     tilt: 0,    phys: (0,    0),    size: 64),
]

private let labelW: CGFloat = 90
private let gap:    CGFloat = 6

struct OutfitGrid: View {
    var body: some View {
        VStack(alignment: .leading, spacing: gap) {
            // Column headers
            HStack(spacing: gap) {
                Spacer().frame(width: labelW)
                ForEach(poses.indices, id: \.self) { i in
                    Text(poses[i].label)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.gray)
                        .frame(width: poses[i].size, alignment: .center)
                }
            }
            // One row per outfit
            ForEach(targetOutfits.indices, id: \.self) { oi in
                let outfit = targetOutfits[oi]
                HStack(spacing: gap) {
                    Text(outfit.rawValue)
                        .font(.system(size: 10))
                        .foregroundColor(.white)
                        .frame(width: labelW, alignment: .trailing)
                    ForEach(poses.indices, id: \.self) { pi in
                        let p = poses[pi]
                        MochiCell(outfit: outfit, yaw: p.yaw, pitch: p.pitch,
                                  tilt: p.tilt, phys: p.phys, cellSize: p.size)
                            .background(pi == poses.count - 1
                                        ? Color.black
                                        : Color(red: 0.083, green: 0.090, blue: 0.106))
                            .clipShape(RoundedRectangle(cornerRadius: pi == poses.count - 1 ? 0 : 8))
                    }
                }
            }
        }
        .padding(12)
        .background(Color(red: 0.043, green: 0.047, blue: 0.055))
    }
}

// MARK: - Roll planche

private let rollOutfits: [Outfit] = [
    .beanie, .santaHat, .witchHat, .crown,
    .sunglasses, .roundGlasses, .scarf, .bow, .pumpkin, .bunnyEars
]

private let rollValues: [CGFloat] = [0, CGFloat.pi/3, CGFloat.pi*2/3, CGFloat.pi, CGFloat.pi*4/3, CGFloat.pi*5/3]

struct RollGrid: View {
    var body: some View {
        VStack(alignment: .leading, spacing: gap) {
            // Column headers
            HStack(spacing: gap) {
                Spacer().frame(width: labelW)
                ForEach(rollValues.indices, id: \.self) { i in
                    Text(String(format: "%.2fπ", rollValues[i] / .pi))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.gray)
                        .frame(width: 120, alignment: .center)
                }
            }
            ForEach(rollOutfits.indices, id: \.self) { oi in
                let outfit = rollOutfits[oi]
                HStack(spacing: gap) {
                    Text(outfit.rawValue)
                        .font(.system(size: 10))
                        .foregroundColor(.white)
                        .frame(width: labelW, alignment: .trailing)
                    ForEach(rollValues.indices, id: \.self) { ri in
                        MochiCell(outfit: outfit, yaw: 0, pitch: 0, tilt: 0, phys: (0, 0),
                                  cellSize: 120, roll: rollValues[ri])
                            .background(Color(red: 0.083, green: 0.090, blue: 0.106))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .padding(12)
        .background(Color(red: 0.043, green: 0.047, blue: 0.055))
    }
}

// MARK: - Transition planche

private let transitionOutfits: [Outfit] = [.witchHat, .santaHat, .bunnyEars, .scarf]
private let presenceValues: [CGFloat] = [0, 0.3, 0.6, 1]

struct TransitionGrid: View {
    var body: some View {
        VStack(alignment: .leading, spacing: gap) {
            // Column headers
            HStack(spacing: gap) {
                Spacer().frame(width: labelW)
                ForEach(presenceValues.indices, id: \.self) { i in
                    Text(String(format: "p=%.1f", presenceValues[i]))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.gray)
                        .frame(width: 120, alignment: .center)
                }
            }
            ForEach(transitionOutfits.indices, id: \.self) { oi in
                let outfit = transitionOutfits[oi]
                HStack(spacing: gap) {
                    Text(outfit.rawValue)
                        .font(.system(size: 10))
                        .foregroundColor(.white)
                        .frame(width: labelW, alignment: .trailing)
                    ForEach(presenceValues.indices, id: \.self) { pi in
                        MochiCell(outfit: outfit, yaw: 0, pitch: 0, tilt: 0, phys: (0, 0),
                                  cellSize: 120, presence: presenceValues[pi])
                            .background(Color(red: 0.083, green: 0.090, blue: 0.106))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .padding(12)
        .background(Color(red: 0.043, green: 0.047, blue: 0.055))
    }
}

// MARK: - Helper to render and save a view

@MainActor
private func renderAndSave<V: View>(_ view: V, path: String) {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2.0
    guard let nsImage = renderer.nsImage else {
        print("Error: ImageRenderer returned nil for \(path)")
        return
    }
    guard let tiff = nsImage.tiffRepresentation,
          let rep  = NSBitmapImageRep(data: tiff),
          let png  = rep.representation(using: .png, properties: [:])
    else {
        print("Error: PNG conversion failed for \(path)")
        return
    }
    do {
        try png.write(to: URL(fileURLWithPath: path))
        print("✓ \(path) — \(Int(nsImage.size.width))×\(Int(nsImage.size.height)) @ 2×")
    } catch {
        print("Error writing \(path): \(error)")
    }
}

// MARK: - Entry point

@main
struct RenderOutfits {
    static func main() {
        MainActor.assumeIsolated {
            renderAndSave(OutfitGrid(),      path: "/tmp/coucou-outfits.png")
            renderAndSave(RollGrid(),        path: "/tmp/coucou-roll.png")
            renderAndSave(TransitionGrid(),  path: "/tmp/coucou-transition.png")
        }
    }
}
