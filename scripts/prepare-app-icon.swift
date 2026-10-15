import AppKit

// Every representation uses the same portrait. AppKit can select a small ICNS
// representation even for a larger view, so substituting different artwork
// would change the app identity between Settings, Finder and the Dock.
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let assets = root.appendingPathComponent("Assets", isDirectory: true)
guard let source = NSImage(contentsOf: assets.appendingPathComponent("TrumpAppIcon-original-generated.png")) else {
    fatalError("Missing application icon artwork")
}
let iconset = assets.appendingPathComponent("TrumpAppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

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
        let canvas = CGFloat(pixels)
        let tile = NSRect(x: canvas * 0.09375, y: canvas * 0.09375,
                          width: canvas * 0.8125, height: canvas * 0.8125)
        let mask = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225,
                                yRadius: tile.height * 0.225)
        mask.addClip()
        let crop = NSRect(x: source.size.width * 0.10, y: source.size.height * 0.11,
                          width: source.size.width * 0.80, height: source.size.height * 0.78)
        source.draw(in: tile, from: crop, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try rep.representation(using: .png, properties: [:])!.write(
            to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
print("Prepared app icon: 16–1024 pixels")
