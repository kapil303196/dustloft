import AppKit
import Foundation

// The Dustloft mark: a pitched roof with a lit window. Warm amber, matching the
// site palette, and legible down to 16px where a detailed scene would mush.

func draw(size S: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setShouldAntialias(true)

    let inset = S * 0.085
    let box = NSRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
    let radius = box.width * 0.2237

    let bg = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
    bg.addClip()
    NSGradient(colors: [
        NSColor(srgbRed: 0.98, green: 0.76, blue: 0.38, alpha: 1),   // lamp amber
        NSColor(srgbRed: 0.90, green: 0.55, blue: 0.20, alpha: 1),
        NSColor(srgbRed: 0.76, green: 0.38, blue: 0.13, alpha: 1)    // deep ochre
    ], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: box, angle: -90)

    let ink = NSColor(srgbRed: 0.13, green: 0.09, blue: 0.06, alpha: 1)   // warm near-black

    // Roof: a wide pitch, drawn as a stroked chevron so it stays crisp small.
    let apexY  = box.minY + box.height * 0.76
    let eaveY  = box.minY + box.height * 0.40
    let leftX  = box.minX + box.width * 0.17
    let rightX = box.maxX - box.width * 0.17
    let midX   = box.midX

    let roof = NSBezierPath()
    roof.move(to: NSPoint(x: leftX, y: eaveY))
    roof.line(to: NSPoint(x: midX,  y: apexY))
    roof.line(to: NSPoint(x: rightX, y: eaveY))
    roof.lineWidth = box.width * 0.115
    roof.lineCapStyle = .round
    roof.lineJoinStyle = .round
    ink.setStroke()
    roof.stroke()

    // Floor line, so it reads as a room rather than an arrow.
    let floor = NSBezierPath()
    floor.move(to: NSPoint(x: leftX, y: box.minY + box.height * 0.235))
    floor.line(to: NSPoint(x: rightX, y: box.minY + box.height * 0.235))
    floor.lineWidth = box.width * 0.115
    floor.lineCapStyle = .round
    floor.stroke()

    // The lit window: a small square the roof shelters.
    let w = box.width * 0.155
    let win = NSBezierPath(roundedRect: NSRect(x: midX - w/2,
                                               y: box.minY + box.height * 0.40,
                                               width: w, height: w),
                           xRadius: w * 0.22, yRadius: w * 0.22)
    ink.setFill()
    win.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/Dustloft.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let variants: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]
for (name, s) in variants {
    guard let png = draw(size: s).representation(using: .png, properties: [:]) else { continue }
    try png.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
print("rendered \(variants.count) sizes")
