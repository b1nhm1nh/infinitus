// Renders the CswapBar app icon (the menubar's ⇄ glyph on a gradient
// squircle) to the PNG path given as argv[1], at exactly 1024×1024 pixels.
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
    NSColor(calibratedRed: 0.95, green: 0.47, blue: 0.18, alpha: 1),  // flame orange
    NSColor(calibratedRed: 0.55, green: 0.17, blue: 0.62, alpha: 1),  // claude-ish purple
])!.draw(in: squircle, angle: -60)

let glyph = "\u{21C4}" as NSString  // ⇄ — the menubar title's switch glyph
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 560, weight: .semibold),
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
