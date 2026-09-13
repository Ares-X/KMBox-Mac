import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let rect = NSRect(x: 72, y: 72, width: 880, height: 880)
        NSColor(calibratedRed: 0.05, green: 0.39, blue: 0.31, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 200, yRadius: 200).fill()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 318, y: 668)); path.line(to: NSPoint(x: 540, y: 512))
        path.line(to: NSPoint(x: 318, y: 356))
        path.lineWidth = 64; path.lineCapStyle = .round; path.lineJoinStyle = .round
        NSColor.white.setStroke(); path.stroke()
        let cursor = NSBezierPath(roundedRect: NSRect(x: 557, y: 325, width: 186, height: 61), xRadius: 30, yRadius: 30)
        NSColor(calibratedRed: 0.67, green: 0.91, blue: 0.73, alpha: 1).setFill(); cursor.fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let name = "icon_\(size)x\(size)\(suffix).png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
