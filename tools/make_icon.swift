import AppKit
import Foundation

// Draws the Attic mark: a disk with a wedge atticed out of it, plus a
// sparkle. Rendered natively at every size so strokes stay crisp at 16px.

func draw(size S: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // macOS icons sit inset inside their canvas.
    let inset = S * 0.085
    let box = NSRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
    let radius = box.width * 0.2237          // Apple's squircle-ish corner ratio

    // Background gradient: blue -> indigo, light source top-left.
    let bg = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
    bg.addClip()
    let grad = NSGradient(colors: [
        NSColor(srgbRed: 0.36, green: 0.60, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.15, green: 0.39, blue: 0.92, alpha: 1),
        NSColor(srgbRed: 0.24, green: 0.21, blue: 0.83, alpha: 1)
    ], atLocations: [0.0, 0.55, 1.0], colorSpace: .sRGB)!
    grad.draw(in: box, angle: -90)

    // Soft top highlight for depth.
    let hi = NSGradient(colors: [NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0)],
                        atLocations: [0, 1], colorSpace: .sRGB)!
    hi.draw(in: NSRect(x: box.minX, y: box.midY, width: box.width, height: box.height / 2), angle: -90)

    // ---- Gauge ring with a gap: the space you just got back ----
    // A stroked arc stays crisp at 16px, where a filled wedge turns to mush.
    let c = NSPoint(x: box.midX, y: box.midY)
    let r = box.width * 0.27
    let lw = r * 0.46

    ctx.setLineCap(.round)

    // Faint remainder of the ring, so the gap reads as a gap.
    let ghost = NSBezierPath()
    ghost.appendArc(withCenter: c, radius: r, startAngle: 128, endAngle: 52)
    ghost.lineWidth = lw
    ghost.lineCapStyle = .round
    NSColor(white: 1, alpha: 0.30).setStroke()
    ghost.stroke()

    // The solid arc.
    let arc = NSBezierPath()
    arc.appendArc(withCenter: c, radius: r, startAngle: 52, endAngle: 128, clockwise: true)
    arc.lineWidth = lw
    arc.lineCapStyle = .round
    NSColor.white.setStroke()
    arc.stroke()

    // ---- Sparkle sitting in the gap ----
    func sparkle(at p: NSPoint, s: CGFloat, alpha: CGFloat) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: p.x, y: p.y + s))
        path.curve(to: NSPoint(x: p.x + s, y: p.y),
                   controlPoint1: NSPoint(x: p.x + s * 0.18, y: p.y + s * 0.18),
                   controlPoint2: NSPoint(x: p.x + s * 0.82, y: p.y + s * 0.18))
        path.curve(to: NSPoint(x: p.x, y: p.y - s),
                   controlPoint1: NSPoint(x: p.x + s * 0.82, y: p.y - s * 0.18),
                   controlPoint2: NSPoint(x: p.x + s * 0.18, y: p.y - s * 0.18))
        path.curve(to: NSPoint(x: p.x - s, y: p.y),
                   controlPoint1: NSPoint(x: p.x - s * 0.18, y: p.y - s * 0.18),
                   controlPoint2: NSPoint(x: p.x - s * 0.82, y: p.y - s * 0.18))
        path.curve(to: NSPoint(x: p.x, y: p.y + s),
                   controlPoint1: NSPoint(x: p.x - s * 0.82, y: p.y + s * 0.18),
                   controlPoint2: NSPoint(x: p.x - s * 0.18, y: p.y + s * 0.18))
        NSColor(white: 1, alpha: alpha).setFill()
        path.fill()
    }
    let gapAngle: CGFloat = 90 * .pi / 180
    let gp = NSPoint(x: c.x + cos(gapAngle) * r, y: c.y + sin(gapAngle) * r)
    sparkle(at: gp, s: lw * 0.78, alpha: 1.0)
    if S >= 64 {
        sparkle(at: NSPoint(x: gp.x + r * 0.52, y: gp.y + r * 0.30), s: lw * 0.34, alpha: 0.92)
        sparkle(at: NSPoint(x: gp.x - r * 0.50, y: gp.y + r * 0.16), s: lw * 0.26, alpha: 0.75)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/Attic.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let variants: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]
for (name, s) in variants {
    let rep = draw(size: s)
    guard let png = rep.representation(using: .png, properties: [:]) else { continue }
    try png.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
print("rendered \(variants.count) sizes into \(outDir)")
