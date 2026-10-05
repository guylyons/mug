import AppKit

/// Draws the menu bar mug. Rendered as a template image so macOS tints it
/// white on a dark menu bar and black on a light one.
enum MugIcon {
    /// `phase` (radians) sways the steam; advance it over time to animate.
    static func image(steaming: Bool, phase: CGFloat = 0) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setStroke()

            // Cup body: open at the top, rounded at the bottom.
            let body = NSBezierPath()
            body.lineWidth = 1.5
            body.lineCapStyle = .round
            body.lineJoinStyle = .round
            body.move(to: NSPoint(x: 2.5, y: 10))
            body.line(to: NSPoint(x: 2.5, y: 4))
            body.appendArc(from: NSPoint(x: 2.5, y: 1.5), to: NSPoint(x: 5, y: 1.5), radius: 2.5)
            body.line(to: NSPoint(x: 10, y: 1.5))
            body.appendArc(from: NSPoint(x: 12.5, y: 1.5), to: NSPoint(x: 12.5, y: 4), radius: 2.5)
            body.line(to: NSPoint(x: 12.5, y: 10))
            body.stroke()

            // Rim.
            let rim = NSBezierPath()
            rim.lineWidth = 1.5
            rim.lineCapStyle = .round
            rim.move(to: NSPoint(x: 2.5, y: 10))
            rim.line(to: NSPoint(x: 12.5, y: 10))
            rim.stroke()

            // Handle.
            let handle = NSBezierPath()
            handle.lineWidth = 1.5
            handle.lineCapStyle = .round
            handle.move(to: NSPoint(x: 12.5, y: 8.5))
            handle.curve(to: NSPoint(x: 12.5, y: 3.5),
                         controlPoint1: NSPoint(x: 16.5, y: 8.5),
                         controlPoint2: NSPoint(x: 16.5, y: 3.5))
            handle.stroke()

            if steaming {
                for (i, x) in [5.0, 9.0].enumerated() {
                    // Wisps sway out of step with each other.
                    let sway = 1.75 * cos(phase + CGFloat(i) * .pi)
                    let steam = NSBezierPath()
                    steam.lineWidth = 1.25
                    steam.lineCapStyle = .round
                    steam.move(to: NSPoint(x: x, y: 11.75))
                    steam.curve(to: NSPoint(x: x, y: 16.75),
                                controlPoint1: NSPoint(x: x + sway, y: 13.5),
                                controlPoint2: NSPoint(x: x - sway, y: 15))
                    steam.stroke()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = steaming ? "Mug (keeping awake)" : "Mug (off)"
        return image
    }
}
