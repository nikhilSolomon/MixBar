// Renders the MixBar app icon: a dark squircle with three faders and a sound wave.
// Usage: swift make_icon.swift <output-dir>   → writes AppIcon.iconset/*.png
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconset = URL(fileURLWithPath: outDir).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { return image }
    let s = size / 1024.0

    // macOS icon grid: 824pt artwork centred on a 1024pt canvas.
    let inset = 100 * s
    let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let radius = rect.width * 0.2237
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 28 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.14, alpha: 1).setFill()
    squircle.fill()
    ctx.restoreGState()

    // Background gradient
    ctx.saveGState()
    squircle.addClip()
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.17, green: 0.17, blue: 0.22, alpha: 1),
        NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.11, alpha: 1),
    ])!
    gradient.draw(in: rect, angle: -90)

    // Soft accent glow bottom-left
    let glow = NSGradient(colors: [
        NSColor(calibratedRed: 0.36, green: 0.42, blue: 1.0, alpha: 0.45),
        NSColor(calibratedRed: 0.36, green: 0.42, blue: 1.0, alpha: 0.0),
    ])!
    glow.draw(fromCenter: CGPoint(x: rect.minX + rect.width * 0.25, y: rect.minY + rect.height * 0.2), radius: 0,
              toCenter: CGPoint(x: rect.minX + rect.width * 0.25, y: rect.minY + rect.height * 0.2), radius: rect.width * 0.7, options: [])
    ctx.restoreGState()

    // Faders
    let trackWidth = 46 * s
    let knobWidth = 150 * s
    let knobHeight = 72 * s
    let xs: [CGFloat] = [0.27, 0.50, 0.73].map { rect.minX + rect.width * $0 }
    let knobLevels: [CGFloat] = [0.62, 0.36, 0.78]
    let trackTop = rect.minY + rect.height * 0.82
    let trackBottom = rect.minY + rect.height * 0.18
    let accent = NSColor(calibratedRed: 0.36, green: 0.55, blue: 1.0, alpha: 1)

    for (i, x) in xs.enumerated() {
        let knobY = trackBottom + (trackTop - trackBottom) * knobLevels[i]

        // Track (dim above knob, lit below)
        let track = NSBezierPath(roundedRect: CGRect(x: x - trackWidth / 2, y: trackBottom, width: trackWidth, height: trackTop - trackBottom),
                                 xRadius: trackWidth / 2, yRadius: trackWidth / 2)
        NSColor.white.withAlphaComponent(0.16).setFill()
        track.fill()
        let lit = NSBezierPath(roundedRect: CGRect(x: x - trackWidth / 2, y: trackBottom, width: trackWidth, height: knobY - trackBottom),
                               xRadius: trackWidth / 2, yRadius: trackWidth / 2)
        accent.setFill()
        lit.fill()

        // Knob
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6 * s), blur: 14 * s, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        let knobRect = CGRect(x: x - knobWidth / 2, y: knobY - knobHeight / 2, width: knobWidth, height: knobHeight)
        let knob = NSBezierPath(roundedRect: knobRect, xRadius: 22 * s, yRadius: 22 * s)
        NSGradient(colors: [NSColor.white, NSColor(calibratedWhite: 0.86, alpha: 1)])!.draw(in: knob, angle: -90)
        ctx.restoreGState()
        // Knob grip line
        let grip = NSBezierPath(roundedRect: CGRect(x: x - knobWidth * 0.3, y: knobY - 5 * s, width: knobWidth * 0.6, height: 10 * s), xRadius: 5 * s, yRadius: 5 * s)
        NSColor(calibratedWhite: 0.55, alpha: 1).setFill()
        grip.fill()
    }

    image.unlockFocus()
    return image
}

func write(_ image: NSImage, pixels: Int, name: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: iconset.appendingPathComponent(name))
}

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = points * scale
    let image = draw(size: CGFloat(pixels))
    write(image, pixels: pixels, name: "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png")
}
print("wrote \(iconset.path)")
