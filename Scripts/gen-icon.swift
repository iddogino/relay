// Renders Resources/AppIcon.icns for Relay.
// Run: swift Scripts/gen-icon.swift && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit
import CoreGraphics

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError() }

    let s = size / 1024.0

    // macOS-style margin: content squircle ~824pt of 1024.
    let inset = 100 * s
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = 185 * s
    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 24 * s,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
    ctx.addPath(squircle)
    ctx.setFillColor(CGColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Background gradient (deep slate)
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let bg = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.16, green: 0.18, blue: 0.25, alpha: 1),
            CGColor(red: 0.07, green: 0.08, blue: 0.12, alpha: 1),
        ] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(
        bg,
        start: CGPoint(x: size / 2, y: size - inset),
        end: CGPoint(x: size / 2, y: inset),
        options: [])

    // Subtle top highlight
    let highlight = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.10),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
        ] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(
        highlight,
        start: CGPoint(x: size / 2, y: size - inset),
        end: CGPoint(x: size / 2, y: size - inset - 260 * s),
        options: [])

    // Relay "signal" arcs, top-right
    ctx.setLineCap(.round)
    let arcCenter = CGPoint(x: 700 * s, y: 700 * s)
    for (i, alpha) in [(1, 0.85), (2, 0.55), (3, 0.3)] {
        ctx.setStrokeColor(CGColor(red: 0.45, green: 0.72, blue: 1.0, alpha: alpha))
        ctx.setLineWidth(26 * s)
        let r = CGFloat(70 + i * 62) * s
        ctx.addArc(center: arcCenter, radius: r,
                   startAngle: .pi * 0.08, endAngle: .pi * 0.42, clockwise: false)
        ctx.strokePath()
    }
    ctx.setFillColor(CGColor(red: 0.45, green: 0.72, blue: 1.0, alpha: 1))
    ctx.addEllipse(in: CGRect(x: arcCenter.x - 30 * s, y: arcCenter.y - 30 * s, width: 60 * s, height: 60 * s))
    ctx.fillPath()

    // Prompt chevron "❯"
    ctx.setStrokeColor(CGColor(gray: 0.98, alpha: 1))
    ctx.setLineWidth(58 * s)
    ctx.setLineJoin(.round)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: 280 * s, y: 560 * s))
    ctx.addLine(to: CGPoint(x: 430 * s, y: 430 * s))
    ctx.addLine(to: CGPoint(x: 280 * s, y: 300 * s))
    ctx.strokePath()

    // Cursor underscore
    ctx.setFillColor(CGColor(red: 0.45, green: 0.72, blue: 1.0, alpha: 1))
    let cursor = CGRect(x: 500 * s, y: 288 * s, width: 190 * s, height: 52 * s)
    ctx.addPath(CGPath(roundedRect: cursor, cornerWidth: 18 * s, cornerHeight: 18 * s, transform: nil))
    ctx.fillPath()

    ctx.restoreGState()
    image.unlockFocus()
    return image
}

let iconsetURL = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let variants: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, px) in variants {
    let image = drawIcon(size: px)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { fatalError() }
    try png.write(to: iconsetURL.appendingPathComponent("\(name).png"))
}
print("wrote \(iconsetURL.path)")
