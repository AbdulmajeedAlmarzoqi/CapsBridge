#!/usr/bin/env swift
// Draws the app icon and writes every size the asset catalog needs.
//
//   swift scripts/make-icon.swift

import AppKit

let iconSet = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset")

/// Draws the icon on a 1024-point canvas: a Caps Lock arrow standing on a bridge.
func drawIcon() {
    let canvas = NSRect(x: 0, y: 0, width: 1024, height: 1024)
    let plate = canvas.insetBy(dx: 100, dy: 100)
    let shape = NSBezierPath(roundedRect: plate, xRadius: 186, yRadius: 186)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor(calibratedRed: 0.17, green: 0.33, blue: 0.78, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.36, green: 0.60, blue: 0.99, alpha: 1),
        ending: NSColor(calibratedRed: 0.14, green: 0.27, blue: 0.72, alpha: 1))!
    gradient.draw(in: shape, angle: -90)

    NSColor.white.set()

    // The bridge: a deck across the plate, an arch under it, and the two shores it joins.
    let deckY: CGFloat = 372
    let left = plate.minX + 150
    let right = plate.maxX - 150
    let deck = NSBezierPath()
    deck.lineWidth = 34
    deck.lineCapStyle = .round
    deck.move(to: NSPoint(x: left, y: deckY))
    deck.line(to: NSPoint(x: right, y: deckY))
    deck.stroke()

    let arch = NSBezierPath()
    arch.lineWidth = 26
    arch.lineCapStyle = .round
    arch.move(to: NSPoint(x: left + 40, y: deckY - 120))
    arch.curve(
        to: NSPoint(x: right - 40, y: deckY - 120),
        controlPoint1: NSPoint(x: left + 170, y: deckY + 30),
        controlPoint2: NSPoint(x: right - 170, y: deckY + 30))
    NSColor.white.withAlphaComponent(0.78).set()
    arch.stroke()

    // The Caps Lock arrow, as keyboards print it.
    NSColor.white.set()
    let centerX = canvas.midX
    let arrow = NSBezierPath()
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: centerX, y: 800))
    arrow.line(to: NSPoint(x: centerX + 176, y: 624))
    arrow.line(to: NSPoint(x: centerX + 84, y: 624))
    arrow.line(to: NSPoint(x: centerX + 84, y: 512))
    arrow.line(to: NSPoint(x: centerX - 84, y: 512))
    arrow.line(to: NSPoint(x: centerX - 84, y: 624))
    arrow.line(to: NSPoint(x: centerX - 176, y: 624))
    arrow.close()
    arrow.lineWidth = 20
    arrow.fill()
    arrow.stroke()

    let base = NSBezierPath(roundedRect: NSRect(x: centerX - 94, y: 428, width: 188, height: 50), xRadius: 14, yRadius: 14)
    base.fill()
}

func png(pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: 1024, height: 1024)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try png(pixels: points * scale).write(to: iconSet.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}

let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: iconSet.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) images to \(iconSet.path)")
