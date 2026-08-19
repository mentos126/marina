import AppKit

/// The Marina mark, drawn for the menu bar: a boat under sail while something is
/// running, and a bare mast in its slip when everything is idle.
///
/// Same 24x24 geometry as `Tools/makeicon.swift`, so the status item and the app
/// icon read as one identity. The image is a template, so macOS tints it for
/// light, dark and highlighted menu bars.
enum MarinaGlyph {
    /// The authored grid, SVG-style, with y growing downwards.
    private static let grid: CGFloat = 24
    private static let lineWidth: CGFloat = 2.3

    /// Ink bounds on the authored grid, measured on the full mark so the status
    /// item keeps one width and one baseline across both states.
    private static let inkBounds = CGRect(
        x: 3.3 - lineWidth / 2,
        y: 2.7,
        width: (20.7 + lineWidth / 2) - (3.3 - lineWidth / 2),
        height: (20.9 + lineWidth / 2) - 2.7
    )

    private static var cache: [Bool: NSImage] = [:]

    /// - Parameter active: sails up when something is running, a bare mast when
    ///   every server is idle.
    static func menuBarImage(active: Bool) -> NSImage {
        if let cached = cache[active] { return cached }
        let image = render(active: active)
        cache[active] = image
        return image
    }

    private static func render(active: Bool) -> NSImage {
        let height: CGFloat = 15
        let scale = height / inkBounds.height
        let size = NSSize(width: inkBounds.width * scale, height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            // AppKit draws bottom-up, so the authored y is mirrored on the way in.
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                NSPoint(
                    x: (x - inkBounds.minX) * scale,
                    y: (inkBounds.maxY - y) * scale
                )
            }

            // Template images care about coverage, not colour.
            NSColor.black.set()

            if active {
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
            } else {
                let mast = NSBezierPath()
                mast.lineWidth = lineWidth * scale
                mast.lineCapStyle = .round
                mast.move(to: point(12, 4.2))
                mast.line(to: point(12, 17.6))
                mast.stroke()
            }

            let hull = NSBezierPath()
            hull.lineWidth = lineWidth * scale
            hull.lineCapStyle = .round
            hull.move(to: point(3.3, 18.3))
            hull.curve(
                to: point(20.7, 18.3),
                controlPoint1: point(5.2, 21.8),
                controlPoint2: point(18.8, 21.8)
            )
            hull.stroke()

            return true
        }

        image.isTemplate = true
        image.accessibilityDescription = "Marina"
        return image
    }
}
