#!/usr/bin/env swift
import AppKit

// Build a resolution-independent app mark without third-party artwork or fonts.
// Usage: swift scripts/icon.swift path/to/Switchboard.icns
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift scripts/icon.swift output.icns\n", stderr)
    exit(1)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("Switchboard-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

func drawIcon(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    let tile = NSBezierPath(roundedRect: NSRect(x: 86, y: 100, width: 852, height: 852), xRadius: 190, yRadius: 190)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
    shadow.shadowBlurRadius = 32
    shadow.shadowOffset = NSSize(width: 0, height: -17)
    shadow.set()
    NSColor(white: 0.08, alpha: 1).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSColor.white.withAlphaComponent(0.16).setStroke()
    tile.lineWidth = 2
    tile.stroke()

    NSColor(white: 0.96, alpha: 1).setStroke()
    let arrows = NSBezierPath()
    arrows.lineWidth = 43
    arrows.lineCapStyle = .round
    arrows.lineJoinStyle = .round
    arrows.move(to: NSPoint(x: 708, y: 655))
    arrows.line(to: NSPoint(x: 322, y: 655))
    arrows.move(to: NSPoint(x: 424, y: 757))
    arrows.line(to: NSPoint(x: 322, y: 655))
    arrows.line(to: NSPoint(x: 424, y: 553))
    arrows.move(to: NSPoint(x: 316, y: 399))
    arrows.line(to: NSPoint(x: 702, y: 399))
    arrows.move(to: NSPoint(x: 600, y: 501))
    arrows.line(to: NSPoint(x: 702, y: 399))
    arrows.line(to: NSPoint(x: 600, y: 297))
    arrows.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let path = iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        try drawIcon(size: size * scale).write(to: path)
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
