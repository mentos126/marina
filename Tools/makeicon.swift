// Renders Marina.icns from the Marina mark: a boat under sail, moored in its
// slip. The same 24x24 geometry is drawn by the menu bar glyph in
// Sources/MarinaApp/MenuBarIcon.swift, so the app icon and the status item read
// as one identity.
// Usage: swift Tools/makeicon.swift <output.icns>

import AppKit
import Foundation

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Marina.icns"
let sizes = [16, 32, 64, 128, 256, 512, 1024]

/// The mark is authored on a 24x24 grid, SVG-style, with y growing downwards.
private let markGrid: CGFloat = 24

private func icon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let inset = size * 0.06
    let body = NSRect(x: 0, y: 0, width: size, height: size).insetBy(dx: inset, dy: inset)
    let radius = size * 0.2237

    let gradient = NSGradient(
        colors: [
            NSColor(calibratedRed: 0.23, green: 0.83, blue: 0.81, alpha: 1),
            NSColor(calibratedRed: 0.06, green: 0.37, blue: 0.82, alpha: 1),
        ]
    )
    let tile = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    gradient?.draw(in: tile, angle: -90)

    // Glyph occupies 66% of the tile body, matching the web lockup.
    let scale = body.width * 0.66 / markGrid
    let originX = body.minX + (body.width - markGrid * scale) / 2
    let originY = body.minY + (body.height - markGrid * scale) / 2

    // AppKit draws bottom-up, so the authored y is mirrored on the way in.
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: originX + x * scale, y: originY + (markGrid - y) * scale)
    }

    NSColor.white.set()

    let mainsail = NSBezierPath()
    mainsail.move(to: point(12.9, 2.7))
    mainsail.line(to: point(12.9, 16.6))
    mainsail.line(to: point(20.3, 16.6))
    mainsail.curve(
        to: point(12.9, 2.7),
        controlPoint1: point(19.4, 11.4),
        controlPoint2: point(16.6, 6.3)
    )
    mainsail.close()
    mainsail.fill()

    let jib = NSBezierPath()
    jib.move(to: point(11.1, 5.8))
    jib.line(to: point(11.1, 16.6))
    jib.line(to: point(5, 16.6))
    jib.curve(
        to: point(11.1, 5.8),
        controlPoint1: point(5.9, 13.6),
        controlPoint2: point(8, 10.1)
    )
    jib.close()
    jib.fill()

    let hull = NSBezierPath()
    hull.lineWidth = 2.3 * scale
    hull.lineCapStyle = .round
    hull.move(to: point(3.3, 18.3))
    hull.curve(
        to: point(20.7, 18.3),
        controlPoint1: point(5.2, 21.8),
        controlPoint2: point(18.8, 21.8)
    )
    hull.stroke()

    image.unlockFocus()
    return image
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Marina.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for size in sizes {
    for scale in [1, 2] {
        let pixels = size * scale
        guard pixels <= 1024 else { continue }
        let image = icon(size: CGFloat(pixels))
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { continue }
        let suffix = scale == 1 ? "" : "@2x"
        let name = "icon_\(size)x\(size)\(suffix).png"
        try png.write(to: iconset.appendingPathComponent(name))
    }
}

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path, "-o", outputPath]
try convert.run()
convert.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("Wrote \(outputPath)")
