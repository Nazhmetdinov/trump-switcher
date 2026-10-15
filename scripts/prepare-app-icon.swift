import AppKit

// Keep the full illustration for Finder and Dock. At 16–32 pt the detailed
// portrait collapses into a noisy thumbnail, so draw a purpose-made mark with
// broad colour fields for the representations used by System Settings.
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let assets = root.appendingPathComponent("Assets", isDirectory: true)
guard let source = NSImage(contentsOf: assets.appendingPathComponent("TrumpAppIcon-original-generated.png")) else {
    fatalError("Missing application icon artwork")
}
let iconset = assets.appendingPathComponent("TrumpAppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func colour(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
    NSColor(calibratedRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
}

func shape(_ points: [NSPoint], fill: NSColor) {
    let path = NSBezierPath()
    path.move(to: points[0])
    for point in points.dropFirst() { path.line(to: point) }
    path.close()
    fill.setFill()
    path.fill()
}

func drawSmallIcon(_ pixels: Int) {
    let scale = CGFloat(pixels) / 100
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()
    let tile = NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 96, height: 96),
                            xRadius: 21, yRadius: 21)
    colour(255, 248, 233).setFill()
    tile.fill()
    tile.addClip()

    // Broad flat shapes carry the recognisable hair, profile and red tie at 16 px.
    shape([NSPoint(x: 2, y: 2), NSPoint(x: 2, y: 38), NSPoint(x: 25, y: 50),
           NSPoint(x: 50, y: 32), NSPoint(x: 74, y: 2)], fill: colour(15, 48, 76))
    shape([NSPoint(x: 43, y: 43), NSPoint(x: 58, y: 39), NSPoint(x: 68, y: 2),
           NSPoint(x: 56, y: 2)], fill: colour(249, 248, 237))
    shape([NSPoint(x: 52, y: 38), NSPoint(x: 60, y: 34), NSPoint(x: 69, y: 2),
           NSPoint(x: 58, y: 2)], fill: colour(187, 31, 34))
    shape([NSPoint(x: 37, y: 39), NSPoint(x: 54, y: 44), NSPoint(x: 59, y: 53),
           NSPoint(x: 45, y: 62), NSPoint(x: 29, y: 52)], fill: colour(207, 104, 52))
    shape([NSPoint(x: 34, y: 84), NSPoint(x: 59, y: 85), NSPoint(x: 73, y: 76),
           NSPoint(x: 79, y: 64), NSPoint(x: 76, y: 56), NSPoint(x: 84, y: 48),
           NSPoint(x: 77, y: 44), NSPoint(x: 80, y: 37), NSPoint(x: 72, y: 32),
           NSPoint(x: 55, y: 37), NSPoint(x: 36, y: 52), NSPoint(x: 27, y: 65)],
          fill: colour(244, 151, 82))
    shape([NSPoint(x: 26, y: 72), NSPoint(x: 29, y: 86), NSPoint(x: 43, y: 94),
           NSPoint(x: 65, y: 92), NSPoint(x: 81, y: 85), NSPoint(x: 91, y: 77),
           NSPoint(x: 82, y: 75), NSPoint(x: 68, y: 79), NSPoint(x: 57, y: 74),
           NSPoint(x: 48, y: 68), NSPoint(x: 43, y: 57), NSPoint(x: 33, y: 55),
           NSPoint(x: 25, y: 63)], fill: colour(225, 158, 33))
    shape([NSPoint(x: 61, y: 64), NSPoint(x: 74, y: 63), NSPoint(x: 70, y: 60),
           NSPoint(x: 61, y: 60)], fill: colour(86, 46, 30))
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        if pixels <= 64 {
            drawSmallIcon(pixels)
        } else {
            let canvas = CGFloat(pixels)
            let tile = NSRect(x: canvas * 0.09375, y: canvas * 0.09375,
                              width: canvas * 0.8125, height: canvas * 0.8125)
            // Keep the portrait untouched inside the standard, inset rounded tile.
            let mask = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225,
                                    yRadius: tile.height * 0.225)
            mask.addClip()
            let crop = NSRect(x: source.size.width * 0.10, y: source.size.height * 0.11,
                              width: source.size.width * 0.80, height: source.size.height * 0.78)
            source.draw(in: tile, from: crop, operation: .copy, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try rep.representation(using: .png, properties: [:])!.write(
            to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
print("Prepared app icon: 16–1024 pixels")
