// Renders the Limitless app icon — the white swap-loop L (same path as
// MenuBarGlyph, which is the design's source of truth) over a
// midnight→violet gradient squircle with a soft center glow — to the PNG
// path given as argv[1], at exactly 1024×1024 pixels. The ∞ mark was
// retired 2026-08-30: not recognizable at small sizes, and the Dock had
// to match the menu bar identity.
// Run by make-icon.sh; not part of the SwiftPM build.
import AppKit

let out = CommandLine.arguments[1]
let px = 1024

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Apple's icon grid: content inset ~10% per side, continuous-corner feel.
let inset: CGFloat = 100
let body = NSRect(x: inset, y: inset,
                  width: CGFloat(px) - 2 * inset, height: CGFloat(px) - 2 * inset)
let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGradient(colors: [
    NSColor(calibratedRed: 0.42, green: 0.20, blue: 0.95, alpha: 1),  // electric violet
    NSColor(calibratedRed: 0.07, green: 0.05, blue: 0.20, alpha: 1),  // midnight indigo
])!.draw(in: squircle, angle: -70)

// Soft glow behind the mark so it reads as luminous, not printed.
squircle.addClip()
NSGradient(colors: [
    NSColor(calibratedWhite: 1.0, alpha: 0.28),
    NSColor(calibratedWhite: 1.0, alpha: 0.0),
])!.draw(
    fromCenter: NSPoint(x: CGFloat(px) / 2, y: CGFloat(px) / 2), radius: 0,
    toCenter: NSPoint(x: CGFloat(px) / 2, y: CGFloat(px) / 2), radius: 380,
    options: []
)

// The swap-loop L, verbatim from MenuBarGlyph's 17×16 design space,
// scaled up and centered (design-box center (8.5, 8) → canvas center).
let s: CGFloat = 40
let transform = NSAffineTransform()
transform.translateX(by: 512 - 8.5 * s, yBy: 512 - 8.0 * s)
transform.scale(by: s)
transform.concat()

NSColor.white.set()
let stroke = NSBezierPath()
stroke.lineWidth = 2.0
stroke.lineCapStyle = .round
stroke.lineJoinStyle = .round
stroke.move(to: NSPoint(x: 3.2, y: 14.2))
stroke.line(to: NSPoint(x: 3.2, y: 3.0))
stroke.line(to: NSPoint(x: 10.2, y: 3.0))
stroke.appendArc(withCenter: NSPoint(x: 10.2, y: 6.2), radius: 3.2,
                 startAngle: -90, endAngle: 90, clockwise: false)
stroke.line(to: NSPoint(x: 9.0, y: 9.4))
stroke.stroke()

let head = NSBezierPath()
head.move(to: NSPoint(x: 6.6, y: 9.4))
head.line(to: NSPoint(x: 10.0, y: 11.2))
head.line(to: NSPoint(x: 10.0, y: 7.6))
head.close()
head.fill()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: out))
