#!/usr/bin/env swift
// Generates the placeholder app icon and menu bar icon (a plain whale on a squircle) into
// NotchBuddy/Assets.xcassets. Nothing here is derived from upstream artwork.
// Usage: swift scripts/make-icons.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.first!)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("NotchBuddy/Assets.xcassets")

func png(size: Int, draw: (CGContext, CGFloat) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    draw(ctx.cgContext, CGFloat(size))
    return rep.representation(using: .png, properties: [:])!
}

/// A whale built from one body squircle, a tail fin and a spout, in a unit box of side `s`.
func whale(_ c: CGContext, s: CGFloat, color: CGColor, eye: CGColor?) {
    c.setFillColor(color)
    let body = CGRect(x: s * 0.14, y: s * 0.26, width: s * 0.62, height: s * 0.40)
    c.addPath(CGPath(roundedRect: body, cornerWidth: s * 0.2, cornerHeight: s * 0.2, transform: nil))
    c.fillPath()
    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: s * 0.70, y: s * 0.40))
    tail.addQuadCurve(to: CGPoint(x: s * 0.88, y: s * 0.62), control: CGPoint(x: s * 0.86, y: s * 0.44))
    tail.addQuadCurve(to: CGPoint(x: s * 0.80, y: s * 0.42), control: CGPoint(x: s * 0.80, y: s * 0.56))
    tail.addQuadCurve(to: CGPoint(x: s * 0.90, y: s * 0.34), control: CGPoint(x: s * 0.92, y: s * 0.40))
    tail.addQuadCurve(to: CGPoint(x: s * 0.70, y: s * 0.32), control: CGPoint(x: s * 0.82, y: s * 0.30))
    tail.closeSubpath()
    c.addPath(tail); c.fillPath()
    for (dx, dy, r) in [(0.0, 0.0, 0.035), (-0.03, 0.07, 0.028), (0.04, 0.12, 0.022)] as [(CGFloat, CGFloat, CGFloat)] {
        c.fillEllipse(in: CGRect(x: s * (0.40 + dx) - s * r, y: s * (0.72 + dy) - s * r, width: s * r * 2, height: s * r * 2))
    }
    if let eye {
        c.setFillColor(eye)
        c.fillEllipse(in: CGRect(x: s * 0.26, y: s * 0.43, width: s * 0.05, height: s * 0.07))
    }
}

func appIcon(_ c: CGContext, s: CGFloat) {
    let inset = s * 0.06
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    c.addPath(CGPath(roundedRect: rect, cornerWidth: s * 0.225, cornerHeight: s * 0.225, transform: nil))
    c.clip()
    let colors = [CGColor(red: 0.10, green: 0.16, blue: 0.30, alpha: 1), CGColor(red: 0.05, green: 0.07, blue: 0.13, alpha: 1)] as CFArray
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    c.drawLinearGradient(g, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    whale(c, s: s, color: CGColor(red: 0.45, green: 0.72, blue: 1, alpha: 1), eye: CGColor(red: 0.05, green: 0.07, blue: 0.13, alpha: 1))
}

let iconset = root.appendingPathComponent("AppIcon.appiconset")
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                   ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
                   ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    try! png(size: px) { c, s in appIcon(c, s: s) }.write(to: iconset.appendingPathComponent("\(name).png"))
}
let menubar = root.appendingPathComponent("MenuBarIcon.imageset")
for (name, px) in [("menubar", 18), ("menubar@2x", 36), ("menubar@3x", 54)] {
    try! png(size: px) { c, s in whale(c, s: s, color: CGColor(gray: 0, alpha: 1), eye: nil) }
        .write(to: menubar.appendingPathComponent("\(name).png"))
}
print("icons written to \(root.path)")
