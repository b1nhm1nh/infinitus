import AppKit

/// The status-item glyph: the Infinitus twin loop — two rings fused at
/// the center into a lemniscate. Reads as ∞ at Dock size and as two
/// linked circles at 16pt, which is where the old single-stroke ∞ failed
/// (blur, 2026-08-30). This path is the identity's source of truth —
/// make-icon.swift scales the same coordinates up for AppIcon.icns and
/// adds the swap arrow the bar is too small for. Template image, so the
/// bar tints it for light/dark and the pressed state.
enum MenuBarGlyph {
    /// Ring geometry in the 17×16 design box; shared with make-icon.swift.
    static let radius: CGFloat = 3.2
    static let leftCenter = NSPoint(x: 6.0, y: 8.0)
    static let rightCenter = NSPoint(x: 11.0, y: 8.0)

    static let image: NSImage = {
        let img = NSImage(size: NSSize(width: 17, height: 16), flipped: false) { _ in
            NSColor.black.set()
            let stroke = NSBezierPath()
            stroke.lineWidth = 2.0
            stroke.appendOval(in: NSRect(x: leftCenter.x - radius, y: leftCenter.y - radius,
                                         width: radius * 2, height: radius * 2))
            stroke.appendOval(in: NSRect(x: rightCenter.x - radius, y: rightCenter.y - radius,
                                         width: radius * 2, height: radius * 2))
            stroke.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }()
}
