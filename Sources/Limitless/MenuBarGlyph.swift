import AppKit

/// The status-item glyph: a rounded "L" whose foot sweeps up into a
/// return loop capped with an arrowhead — Limitless identity plus
/// "rotates accounts" motion. Deliberately NOT the app icon's plain ∞:
/// at menu bar size ∞ wasn't recognizable (user-verified; concept picked
/// 2026-08-30). Template image, so the bar tints it for menu bar
/// light/dark and the pressed state.
enum MenuBarGlyph {
    static let image: NSImage = {
        let img = NSImage(size: NSSize(width: 17, height: 16), flipped: false) { _ in
            NSColor.black.set()

            let stroke = NSBezierPath()
            stroke.lineWidth = 2.0
            stroke.lineCapStyle = .round
            stroke.lineJoinStyle = .round
            // The L: stem, then foot.
            stroke.move(to: NSPoint(x: 3.2, y: 14.2))
            stroke.line(to: NSPoint(x: 3.2, y: 3.0))
            stroke.line(to: NSPoint(x: 10.2, y: 3.0))
            // The foot curls up and back left (the return loop).
            stroke.appendArc(withCenter: NSPoint(x: 10.2, y: 6.2), radius: 3.2,
                             startAngle: -90, endAngle: 90, clockwise: false)
            stroke.line(to: NSPoint(x: 9.0, y: 9.4))
            stroke.stroke()

            // Arrowhead pointing left at the loop's end.
            let head = NSBezierPath()
            head.move(to: NSPoint(x: 6.6, y: 9.4))
            head.line(to: NSPoint(x: 10.0, y: 11.2))
            head.line(to: NSPoint(x: 10.0, y: 7.6))
            head.close()
            head.fill()
            return true
        }
        img.isTemplate = true
        return img
    }()
}
