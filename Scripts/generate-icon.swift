#!/usr/bin/env swift
import AppKit

// Rebuild with: swift Scripts/generate-icon.swift
// Then: iconutil -c icns outputs/AppIcon.iconset -o Resources/AppIcon.icns
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent("outputs/AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(size: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = AffineTransform(scale: CGFloat(size) / 1024)
    (transform as NSAffineTransform).concat()

    let tile = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864),
                            xRadius: 194, yRadius: 194)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor(calibratedRed: 0.08, green: 0.18, blue: 0.32, alpha: 1).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.25, blue: 0.43, alpha: 1),
                        NSColor(calibratedRed: 0.28, green: 0.51, blue: 0.73, alpha: 1)])!
        .draw(in: tile, angle: 70)
    NSColor.white.withAlphaComponent(0.18).setStroke()
    tile.lineWidth = 3
    tile.stroke()

    // A chat window with a terminal prompt, readable at small Finder sizes.
    let bubble = NSBezierPath(roundedRect: NSRect(x: 214, y: 326, width: 596, height: 414),
                              xRadius: 86, yRadius: 86)
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: 304, y: 350))
    tail.line(to: NSPoint(x: 304, y: 235))
    tail.curve(to: NSPoint(x: 331, y: 223), controlPoint1: NSPoint(x: 304, y: 220),
               controlPoint2: NSPoint(x: 316, y: 213))
    tail.line(to: NSPoint(x: 462, y: 350))
    tail.close()
    NSColor(calibratedRed: 0.94, green: 0.97, blue: 1, alpha: 1).setFill()
    bubble.fill()
    tail.fill()

    let prompt = NSBezierPath()
    prompt.move(to: NSPoint(x: 339, y: 615))
    prompt.line(to: NSPoint(x: 420, y: 538))
    prompt.line(to: NSPoint(x: 339, y: 461))
    prompt.lineWidth = 42
    prompt.lineCapStyle = .round
    prompt.lineJoinStyle = .round
    NSColor(calibratedRed: 0.16, green: 0.34, blue: 0.52, alpha: 1).setStroke()
    prompt.stroke()
    let cursor = NSBezierPath(roundedRect: NSRect(x: 480, y: 444, width: 148, height: 40),
                              xRadius: 20, yRadius: 20)
    NSColor(calibratedRed: 0.16, green: 0.34, blue: 0.52, alpha: 1).setFill()
    cursor.fill()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let name = "icon_\(points)x\(points)\(suffix).png"
        try render(size: points * scale).write(to: iconset.appendingPathComponent(name))
    }
}
