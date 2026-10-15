import AppKit

// Native, resolution-independent artwork. The application and destination remain
// real Finder icons; neither is baked into the installer background.
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = root.appendingPathComponent("Assets/Installer", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let width: CGFloat = 760
let height: CGFloat = 600

func color(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
            green: CGFloat((value >> 8) & 255) / 255,
            blue: CGFloat(value & 255) / 255, alpha: alpha)
}
let cream = color(0xF6F0E4)
let muted = color(0xA6B3C4)
let gold = color(0xEDBD70)

func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat,
          weight: NSFont.Weight = .regular, ink: NSColor = cream,
          centered: Bool = false, tracking: CGFloat = 0) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: ink, .kern: tracking
    ]
    let value = NSAttributedString(string: string, attributes: attributes)
    let origin = NSPoint(x: centered ? x - value.size().width / 2 : x,
                         y: height - y - value.size().height)
    precondition(origin.x >= 0 && origin.y >= 0 &&
                 origin.x + value.size().width <= width && y >= 0,
                 "Installer text exceeds the canvas: \(string)")
    value.draw(at: origin)
}

func path(_ points: [(CGFloat, CGFloat)], ink: NSColor, line: CGFloat) {
    let p = NSBezierPath()
    p.lineWidth = line
    p.lineCapStyle = .round
    p.lineJoinStyle = .round
    p.move(to: NSPoint(x: points[0].0, y: height - points[0].1))
    for point in points.dropFirst() {
        p.line(to: NSPoint(x: point.0, y: height - point.1))
    }
    ink.setStroke(); p.stroke()
}

func background() {
    let rect = NSRect(x: 0, y: 0, width: width, height: height)
    NSGradient(starting: color(0x101925), ending: color(0x26354A))!
        .draw(in: rect, angle: 32)

    // Restrained oversized arcs add depth without competing with the real icons.
    for (radius, opacity) in [(CGFloat(480), CGFloat(0.055)), (600, 0.035)] {
        let arc = NSBezierPath(ovalIn: NSRect(x: width - radius * 0.6,
                                            y: height - radius * 0.65,
                                            width: radius, height: radius))
        arc.lineWidth = 1
        cream.withAlphaComponent(opacity).setStroke(); arc.stroke()
    }
    text("Trump Switcher", x: 48, y: 24, size: 32, weight: .bold, tracking: -1)
    text("Пишите свободно. Раскладку исправим.", x: 49, y: 69, size: 16, ink: muted)

    let badge = NSBezierPath(roundedRect: NSRect(x: 610, y: height - 66,
                                                width: 102, height: 32),
                             xRadius: 16, yRadius: 16)
    cream.withAlphaComponent(0.065).setFill(); badge.fill()
    text("RU  ⇄  EN", x: 661, y: 42, size: 12, weight: .semibold,
         ink: gold, centered: true, tracking: 0.5)

    text("ПЕРЕТАЩИТЕ В «ПРОГРАММЫ»", x: 380, y: 118, size: 12,
         weight: .semibold, ink: muted, centered: true, tracking: 1.1)

    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 304, y: height - 205))
    arrow.curve(to: NSPoint(x: 455, y: height - 205),
                controlPoint1: NSPoint(x: 351, y: height - 180),
                controlPoint2: NSPoint(x: 409, y: height - 180))
    arrow.lineWidth = 3
    arrow.lineCapStyle = .round
    gold.setStroke(); arrow.stroke()
    path([(443, 191), (455, 205), (437, 208)], ink: gold, line: 3)

    // Finder supplies the real file labels in black; light plates retain contrast.
    for (x, y, w) in [(CGFloat(185), CGFloat(277), CGFloat(200)),
                       (575, 277, 160), (600, 492, 220)] {
        let plate = NSBezierPath(roundedRect: NSRect(x: x - w / 2, y: height - y - 30,
                                                    width: w, height: 30),
                                 xRadius: 10, yRadius: 10)
        cream.setFill(); plate.fill()
    }

    text("Затем откройте Trump Switcher из «Программ».", x: 380, y: 319,
         size: 14, ink: muted, centered: true)

    path([(48, 350.5), (712, 350.5)], ink: cream.withAlphaComponent(0.11), line: 1)

    text("macOS не открывает приложение?", x: 48, y: 374,
         size: 19, weight: .semibold)
    text("Откройте настройки значком справа.", x: 48, y: 412, size: 15, ink: muted)
    text("Нажмите «Всё равно открыть»", x: 48, y: 435, size: 15, ink: cream)
    text("и подтвердите запуск Trump Switcher.", x: 48, y: 458, size: 15, ink: muted)
    text("Только если вы доверяете скачанному приложению.", x: 48, y: 491,
         size: 11, ink: muted)
    path([(48, 535.5), (712, 535.5)], ink: cream.withAlphaComponent(0.11), line: 1)

    // Shield + lock: privacy is a first-class part of the visual identity.
    let shield = NSBezierPath()
    shield.move(to: NSPoint(x: 57, y: height - 551))
    shield.line(to: NSPoint(x: 66, y: height - 555))
    shield.line(to: NSPoint(x: 66, y: height - 563))
    shield.curve(to: NSPoint(x: 57, y: height - 574),
                 controlPoint1: NSPoint(x: 66, y: height - 569),
                 controlPoint2: NSPoint(x: 61, y: height - 572))
    shield.curve(to: NSPoint(x: 48, y: height - 563),
                 controlPoint1: NSPoint(x: 53, y: height - 572),
                 controlPoint2: NSPoint(x: 48, y: height - 569))
    shield.line(to: NSPoint(x: 48, y: height - 555)); shield.close()
    shield.lineWidth = 1.5; gold.setStroke(); shield.stroke()
    let lock = NSBezierPath(roundedRect: NSRect(x: 54, y: height - 566,
                                               width: 6, height: 5), xRadius: 1, yRadius: 1)
    gold.setFill(); lock.fill()
    let shackle = NSBezierPath(roundedRect: NSRect(x: 55, y: height - 563,
                                                  width: 4, height: 6), xRadius: 2, yRadius: 2)
    shackle.lineWidth = 1; gold.setStroke(); shackle.stroke()
    text("Ваш текст остаётся на вашем Mac", x: 80, y: 546, size: 14, weight: .semibold)
    text("Без интернета, облака и истории набора.", x: 80, y: 568, size: 12, ink: muted)
    text("macOS 13+  ·  Apple Silicon", x: 628, y: 567, size: 11,
         ink: muted, centered: true)
}

func render(scale: Int, preview: Bool = false) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                              pixelsWide: Int(width) * scale, pixelsHigh: Int(height) * scale,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    // NSGraphicsContext uses rep.size to apply the backing scale already.
    background()
    if preview {
        let app = NSImage(contentsOf: root.appendingPathComponent("Assets/TrumpAppIcon.icns"))!
        let folder = NSImage(contentsOfFile: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ApplicationsFolderIcon.icns")
            ?? NSWorkspace.shared.icon(forFile: "/Applications")
        for (image, x) in [(app, CGFloat(185)), (folder, CGFloat(575))] {
            image.draw(in: NSRect(x: x - 64, y: height - 205 - 64, width: 128, height: 128))
        }
        text("Trump Switcher", x: 185, y: 281, size: 14, ink: color(0x172231), centered: true)
        text("Программы", x: 575, y: 281, size: 14, ink: color(0x172231), centered: true)
        let settings = NSImage(contentsOfFile: "/System/Applications/System Settings.app/Contents/Resources/Settings.icns")!
        settings.draw(in: NSRect(x: 536, y: height - 420 - 64, width: 128, height: 128))
        text("Настройки безопасности", x: 600, y: 496, size: 14, ink: color(0x172231), centered: true)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for scale in 1...2 {
    let rep = render(scale: scale)
    let name = scale == 1 ? "background.png" : "background@2x.png"
    try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
}
let representations = [render(scale: 1), render(scale: 2)]
try NSBitmapImageRep.representationOfImageReps(in: representations, using: .tiff,
    properties: [.compressionMethod: NSNumber(value: NSBitmapImageRep.TIFFCompression.lzw.rawValue)])!
    .write(to: output.appendingPathComponent("background.tiff"))
try render(scale: 2, preview: true).representation(using: .png, properties: [:])!
    .write(to: output.appendingPathComponent("preview.png"))
