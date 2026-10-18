import AppKit

// A | Я: a compact, typography-inspired menu-bar mark drawn at every backing scale.
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let assets = root.appendingPathComponent("Assets", isDirectory: true)
func stroke(_ path: NSBezierPath, width: CGFloat) {
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.stroke()
}
func drawIcon(in rect: NSRect) {
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: rect.minX, yBy: rect.minY)
    t.scaleX(by: rect.width / 22, yBy: rect.height / 22)
    t.concat()
    NSColor.black.setStroke()

    // The menu-bar canvas stays 22 pt, while the ink occupies a centered,
    // shorter mark. Transform points instead of the graphics context so the
    // hairlines retain their intended weight at 1x and Retina resolutions.
    func point(_ x: CGFloat, _ y: CGFloat, offsetX: CGFloat = 0) -> NSPoint {
        NSPoint(x: 11 + (x - 11) * 0.78 + offsetX, y: 11 + (y - 11) * 0.72)
    }
    // Keep a visible gap on both sides of the divider, including the feet of
    // the letters. Spacing is in points so it remains clear at every scale.
    func left(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        point(x, y, offsetX: -1.1)
    }
    func right(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        point(x, y, offsetX: 1.1)
    }

    let latin = NSBezierPath()
    latin.move(to: left(1.8, 4.0))
    latin.line(to: left(5.85, 18.0))
    latin.line(to: left(9.35, 4.0))
    latin.move(to: left(3.35, 9.15))
    latin.line(to: left(8.0, 9.15))
    stroke(latin, width: 1.45)

    let separator = NSBezierPath()
    separator.move(to: point(11.25, 2.8))
    separator.line(to: point(11.25, 19.2))
    stroke(separator, width: 0.85)

    let cyrillic = NSBezierPath()
    cyrillic.move(to: right(19.9, 4.0))
    cyrillic.line(to: right(19.9, 18.0))
    cyrillic.line(to: right(16.35, 18.0))
    cyrillic.curve(to: right(13.35, 15.1),
                   controlPoint1: right(14.45, 18.0),
                   controlPoint2: right(13.35, 16.85))
    cyrillic.curve(to: right(16.35, 12.05),
                   controlPoint1: right(13.35, 13.35),
                   controlPoint2: right(14.45, 12.05))
    cyrillic.line(to: right(19.9, 12.05))
    cyrillic.move(to: right(16.35, 12.05))
    cyrillic.line(to: right(13.15, 4.0))
    stroke(cyrillic, width: 1.45)
    NSGraphicsContext.restoreGraphicsState()
}

func bitmap(width: Int, height: Int, draw: (NSRect) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    draw(NSRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let master = bitmap(width: 1024, height: 1024) { drawIcon(in: $0) }
try master.representation(using: .png, properties: [:])!.write(to: assets.appendingPathComponent("TrumpMenuBar-master.png"))

for scale in 1...3 {
    let rep = bitmap(width: 22 * scale, height: 22 * scale) { rect in
        drawIcon(in: rect)
    }
    let suffix = scale == 1 ? "" : "@\(scale)x"
    try rep.representation(using: .png, properties: [:])!.write(
        to: assets.appendingPathComponent("TrumpMenuBar\(suffix).png"))
}

// Inspection sheet: enlarged artwork and actual-size rows next to system symbols.
let preview = bitmap(width: 640, height: 280) { rect in
    NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
    rect.fill()
    drawIcon(in: NSRect(x: 30, y: 102, width: 150, height: 150))
    let template = NSImage(contentsOf: assets.appendingPathComponent("TrumpMenuBar@2x.png"))!
    template.size = NSSize(width: 22, height: 22)
    template.isTemplate = true
    for (row, dark) in [(NSRect(x: 215, y: 170, width: 400, height: 42), false),
                        (NSRect(x: 215, y: 105, width: 400, height: 42), true)] {
        (dark ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor.white).setFill()
        row.fill()
        let color = dark ? NSColor.white : NSColor.black
        let images = ["speaker.wave.2", "play.circle", "battery.100percent", "wifi", "trump", "magnifyingglass", "switch.2"]
        for (index, name) in images.enumerated() {
            let icon = name == "trump" ? template : NSImage(systemSymbolName: name, accessibilityDescription: nil)!
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))!
            let size = name == "trump" ? NSSize(width: 22, height: 22) : icon.size
            let itemRect = NSRect(x: row.minX + 24 + Double(index) * 52,
                                  y: row.midY - size.height / 2, width: size.width, height: size.height)
            let tinted = NSImage(size: size)
            tinted.lockFocus()
            icon.draw(in: NSRect(origin: .zero, size: size))
            color.setFill()
            NSRect(origin: .zero, size: size).fill(using: .sourceIn)
            tinted.unlockFocus()
            tinted.draw(in: itemRect)
        }
    }
    let text = "Вариант 02 · A│Я · 22 pt · 1× / 2× / 3×"
    text.draw(at: NSPoint(x: 30, y: 35), withAttributes: [
        .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.black])
}
try preview.representation(using: .png, properties: [:])!.write(
    to: assets.appendingPathComponent("TrumpMenuBar-preview.png"))
print("Prepared 22-pt menu icon with 1×, 2× and 3× representations and inspection sheet")
