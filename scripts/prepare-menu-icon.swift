import AppKit

// Option 02: paired arrows, rendered as native paths at every backing scale.
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let assets = root.appendingPathComponent("Assets", isDirectory: true)
func drawArrow() {
    let shaft = NSBezierPath()
    shaft.lineWidth = 1.65
    shaft.lineCapStyle = .round
    shaft.move(to: NSPoint(x: 3.65, y: 11.25))
    shaft.curve(to: NSPoint(x: 17.35, y: 14.65),
                controlPoint1: NSPoint(x: 3.95, y: 18.1),
                controlPoint2: NSPoint(x: 13.45, y: 19.25))
    shaft.stroke()

    let head = NSBezierPath()
    head.lineWidth = 1.65
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.move(to: NSPoint(x: 14.75, y: 15.05))
    head.line(to: NSPoint(x: 17.35, y: 14.65))
    head.line(to: NSPoint(x: 18.25, y: 17.15))
    head.stroke()
}
func drawIcon(in rect: NSRect) {
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: rect.minX, yBy: rect.minY)
    t.scaleX(by: rect.width / 22, yBy: rect.height / 22)
    t.concat()
    NSColor.black.setFill(); NSColor.black.setStroke()
    drawArrow()
    // Rotating the same path makes both curves and arrowheads exactly symmetric.
    let opposite = NSAffineTransform()
    opposite.translateX(by: 22, yBy: 22)
    opposite.rotate(byDegrees: 180)
    opposite.concat()
    drawArrow()
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
    let text = "Вариант 02 · симметричные стрелки · 22 pt · 1× / 2× / 3×"
    text.draw(at: NSPoint(x: 30, y: 35), withAttributes: [
        .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.black])
}
try preview.representation(using: .png, properties: [:])!.write(
    to: assets.appendingPathComponent("TrumpMenuBar-preview.png"))
print("Prepared 22-pt menu icon with 1×, 2× and 3× representations and inspection sheet")
