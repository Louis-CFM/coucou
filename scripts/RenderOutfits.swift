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

// MARK: - Mochi body helpers (inline, no BotEngine needed)

private func mochiSuperellipse(rx: CGFloat, ry: CGFloat) -> Path {
    let n = 72
    let expN: CGFloat = 2.0 / 2.7
    var path = Path()
    for i in 0...n {
        let a = CGFloat(i) / CGFloat(n) * .pi * 2
        let ca = cos(a), sa = sin(a)
        let px = rx * (ca >= 0 ? pow(ca, expN) : -pow(-ca, expN))
        let py = ry * (sa >= 0 ? pow(sa, expN) : -pow(-sa, expN))
        if i == 0 { path.move(to: CGPoint(x: px, y: py)) }
        else       { path.addLine(to: CGPoint(x: px, y: py)) }
    }
    path.closeSubpath()
    return path
}

// MARK: - Cell view — one outfit at one pose

struct MochiCell: View {
    let outfit: Outfit
    let yaw: CGFloat
    let pitch: CGFloat
    let cellSize: CGFloat

    var body: some View {
        Canvas { context, sz in
            let W = sz.width, H = sz.height
            let R  = W * 0.3
            let rx = R * 1.14
            let ry = R * 0.88
            let cx = W / 2
            let cy = H / 2 + R * 0.06
            let tilt: CGFloat = 0
            let sx: CGFloat = 1, sy: CGFloat = 1
            let morph: CGFloat = 0, roll: CGFloat = 0

            // 1. Behind-body outfit (bunny ears)
            drawOutfitBehindStatic(
                context: context, outfit: outfit,
                cx: cx, cy: cy, tilt: tilt, sx: sx, sy: sy,
                yaw: yaw, roll: roll, morph: morph,
                R: R, rx: rx, ry: ry, isMini: false
            )

            // 2. Body (replicate BotEngine.drawBody for idle state)
            var bCtx = context
            bCtx.translateBy(x: cx, y: cy)
            let body = mochiSuperellipse(rx: rx, ry: ry)

            // Base gradient
            let cTop = Color(red: 0.929, green: 0.929, blue: 0.937)
            let cBot = Color(red: 0.769, green: 0.773, blue: 0.792)
            bCtx.fill(body, with: .linearGradient(
                Gradient(colors: [cTop, cBot]),
                startPoint: CGPoint(x: rx * 0.7, y: -ry * 0.85),
                endPoint:   CGPoint(x: -rx * 0.8, y: ry * 0.9)
            ))
            // Pumpkin orange tint
            if outfit == .pumpkin {
                bCtx.fill(body, with: .linearGradient(
                    Gradient(colors: [Color(hex: "#F97316").opacity(0.82),
                                      Color(hex: "#EA580C").opacity(0.90)]),
                    startPoint: CGPoint(x: rx * 0.5, y: -ry * 0.8),
                    endPoint:   CGPoint(x: -rx * 0.5, y: ry * 0.8)
                ))
            }
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
            for sd: Double in [-1.0, 1.0] {
                let eyeYaw = CGFloat(sd) * MochiConst.eyeSp + yaw
                var eyePitch = MochiConst.eyeP + pitch
                eyePitch = ((eyePitch + .pi)
                    .truncatingRemainder(dividingBy: .pi * 2) + .pi * 2)
                    .truncatingRemainder(dividingBy: .pi * 2) - .pi
                let cp = cos(eyePitch)
                guard cos(eyeYaw) * cp > 0.04 else { continue }
                let ex = sin(eyeYaw) * cp * rx
                let ey = -sin(eyePitch) * ry
                let fx = max(0.18, cos(eyeYaw))
                let fy = max(0.18, cp)
                let ew = R * MochiConst.eyeW
                let eh = R * MochiConst.eyeH
                var eCtx = eyeBase
                eCtx.translateBy(x: ex, y: ey)
                eCtx.scaleBy(x: fx, y: fy)
                let hh = max(eh, ew * 0.3)
                var pill = Path()
                pill.addRoundedRect(
                    in: CGRect(x: -ew / 2, y: -hh / 2, width: ew, height: hh),
                    cornerSize: CGSize(width: min(ew / 2, hh / 2), height: min(ew / 2, hh / 2))
                )
                eCtx.fill(pill, with: .color(ink))
            }

            // 4. Front outfit (hats, glasses, bow, scarf, pumpkin details)
            drawOutfitFrontStatic(
                context: context, outfit: outfit,
                cx: cx, cy: cy, tilt: tilt, sx: sx, sy: sy,
                yaw: yaw, pitch: pitch, roll: roll, morph: morph,
                R: R, rx: rx, ry: ry, isMini: false, bodyColor: nil
            )
        }
        .frame(width: cellSize, height: cellSize)
    }
}

// MARK: - Grid view

private let targetOutfits: [Outfit] = [
    .none, .partyHat, .beanie, .crown, .witchHat, .santaHat,
    .bunnyEars, .bow, .sunglasses, .roundGlasses, .scarf, .pumpkin,
]

private struct PoseSpec {
    let yaw: CGFloat
    let pitch: CGFloat
    let label: String
    let size: CGFloat
}

private let poses: [PoseSpec] = [
    PoseSpec(yaw: -0.45, pitch: 0,     label: "L",       size: 80),
    PoseSpec(yaw:  0,    pitch: 0,     label: "front",   size: 80),
    PoseSpec(yaw:  0.45, pitch: 0,     label: "R",       size: 80),
    PoseSpec(yaw:  0,    pitch: -0.45, label: "up",      size: 80),
    PoseSpec(yaw:  0,    pitch: 0,     label: "compact", size: 56),
]

private let labelW: CGFloat = 90
private let gap:    CGFloat = 3

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
                    Text(outfit.displayName)
                        .font(.system(size: 9))
                        .foregroundColor(.white)
                        .frame(width: labelW, alignment: .trailing)
                    ForEach(poses.indices, id: \.self) { pi in
                        let p = poses[pi]
                        MochiCell(outfit: outfit, yaw: p.yaw, pitch: p.pitch,
                                  cellSize: p.size)
                            .background(Color(red: 0.07, green: 0.075, blue: 0.09))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
        }
        .padding(10)
        .background(Color(red: 0.043, green: 0.047, blue: 0.055))
    }
}

// MARK: - Entry point

@main
struct RenderOutfits {
    static func main() {
        MainActor.assumeIsolated {
            let renderer = ImageRenderer(content: OutfitGrid())
            renderer.scale = 2.0

            guard let nsImage = renderer.nsImage else {
                print("Error: ImageRenderer returned nil")
                Foundation.exit(1)
            }
            guard let tiff = nsImage.tiffRepresentation,
                  let rep  = NSBitmapImageRep(data: tiff),
                  let png  = rep.representation(using: .png, properties: [:])
            else {
                print("Error: PNG conversion failed")
                Foundation.exit(1)
            }

            let path = "/tmp/coucou-outfits.png"
            do {
                try png.write(to: URL(fileURLWithPath: path))
                print("✓ \(path) — \(Int(nsImage.size.width))×\(Int(nsImage.size.height)) @ 2×")
            } catch {
                print("Error writing PNG: \(error)")
                Foundation.exit(1)
            }
        }
    }
}
