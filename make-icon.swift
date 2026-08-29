// Renders the Limitless app icon — a white ∞ over a midnight→violet
// gradient squircle with a soft center glow — to the PNG path given as
// argv[1], at exactly 1024×1024 pixels.
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

// Soft glow behind the mark so the ∞ reads as luminous, not printed.
squircle.addClip()
NSGradient(colors: [
    NSColor(calibratedWhite: 1.0, alpha: 0.28),
    NSColor(calibratedWhite: 1.0, alpha: 0.0),
])!.draw(
    fromCenter: NSPoint(x: CGFloat(px) / 2, y: CGFloat(px) / 2), radius: 0,
    toCenter: NSPoint(x: CGFloat(px) / 2, y: CGFloat(px) / 2), radius: 380,
    options: []
)

let glyph = "\u{221E}" as NSString  // ∞ — Limitless
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 700, weight: .bold),
    .foregroundColor: NSColor.white,
]
let gsize = glyph.size(withAttributes: attrs)
glyph.draw(
    at: NSPoint(x: (CGFloat(px) - gsize.width) / 2,
                y: (CGFloat(px) - gsize.height) / 2),
    withAttributes: attrs
)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: out))
