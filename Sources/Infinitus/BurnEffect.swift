import SwiftUI

/// Pace-fire overlays for GaugeBar: when a window burns faster than
/// time passes, its bar catches fire (user 2026-08-31 — "flaming or
/// FFVII limit break"). Three auditionable styles; `heat` 0…1
/// (GaugeMath.burnHeat — +30 points ahead saturates) scales size,
/// count, speed and brightness.
///
/// TimelineView(.animation) exists ONLY while something burns (the
/// caller gates on heat > 0 and style) so idle popups pay nothing.
/// All flicker derives from the timeline date + hashed seeds — never
/// Double.random per frame (that strobes instead of flickering).
struct BurnOverlay: View {
    let style: String
    let heat: Double
    let fillFraction: Double   // 0…1, the animated fill tip
    let barWidth: Double
    let barHeight: Double

    /// Flames rise at most this far above the capsule — grid rows sit
    /// close; taller licks bleed into the row above.
    private let rise: Double = 6

    var body: some View {
        TimelineView(.animation) { ctx in
            Canvas { c, size in
                guard fillFraction > 0.03, heat > 0 else { return }
                let t = ctx.date.timeIntervalSinceReferenceDate
                let bar = CGRect(x: 0, y: rise, width: size.width,
                                 height: size.height - rise)
                let tipX = bar.width * fillFraction
                switch style {
                case "ember": ember(&c, t, bar, tipX)
                case "flame": flame(&c, t, bar, tipX)
                case "limit": limit(&c, t, bar, tipX)
                default: break
                }
            }
        }
        .frame(width: barWidth, height: barHeight + rise)
        .allowsHitTesting(false)
    }

    // MARK: shared bits

    private var bright: Double { 0.45 + 0.55 * heat }

    /// Deterministic hash noise 0…1 (replayable, unlike Double.random).
    private func n(_ i: Double) -> Double {
        let v = sin(i * 12.9898) * 43758.5453
        return v - v.rounded(.down)
    }
    private func fract(_ v: Double) -> Double { v - v.rounded(.down) }

    private let emberOrange = Color(red: 1.00, green: 0.45, blue: 0.10)
    private let flameYellow = Color(red: 1.00, green: 0.85, blue: 0.30)
    private let coreWhite   = Color(red: 1.00, green: 0.96, blue: 0.85)

    /// Sparks drifting up off the fill tip (ember + flame styles).
    private func sparks(_ c: inout GraphicsContext, _ t: Double,
                        _ bar: CGRect, _ tipX: Double, count: Int) {
        for i in 0..<count {
            let seed = Double(i) * 7.31
            let cycle = 0.8 + n(seed) * 0.9
            let ph = fract(t / cycle + n(seed + 1))
            let x = tipX - 1 + sin(t * (2.5 + n(seed + 2) * 2) + seed) * 2.5
                     - n(seed + 3) * 5 * ph
            let y = bar.midY - ph * (bar.midY + 1)
            let r = 0.9 * (1 - ph * 0.6)
            c.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r,
                                          width: r * 2, height: r * 2)),
                   with: .color(flameYellow.opacity((1 - ph) * bright)))
        }
    }

    // MARK: styles

    /// Ember glow — a pulsing coal at the fill tip, a few sparks.
    private func ember(_ c: inout GraphicsContext, _ t: Double,
                       _ bar: CGRect, _ tipX: Double) {
        let flick = 0.75 + 0.25 * sin(t * 5.5 + sin(t * 9.3) * 1.3)
        let r = (2.4 + 3.2 * heat) * flick
        let center = CGPoint(x: tipX, y: bar.midY)
        c.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r,
                                      width: r * 2, height: r * 2)),
               with: .radialGradient(
                   Gradient(stops: [
                       .init(color: coreWhite.opacity(0.9 * bright), location: 0),
                       .init(color: emberOrange.opacity(0.6 * bright), location: 0.45),
                       .init(color: emberOrange.opacity(0), location: 1),
                   ]),
                   center: center, startRadius: 0, endRadius: r))
        sparks(&c, t, bar, tipX, count: 1 + Int(heat * 2.99))
    }

    /// Flame licks — tongues rising off the fill tip region.
    private func flame(_ c: inout GraphicsContext, _ t: Double,
                       _ bar: CGRect, _ tipX: Double) {
        let count = 2 + Int(heat * 2.99)               // 2…4 tongues
        let span = min(tipX, 8 + 12 * heat)
        for i in 0..<count {
            let seed = Double(i) * 3.77
            let fx = tipX - span * Double(i) / Double(count)
            let hFlick = 0.65 + 0.35 * sin(t * (4.5 + n(seed) * 3.5) + seed * 11)
            let h = (2.5 + (rise + barHeight * 0.5 - 2.5) * heat) * hFlick
            let sway = sin(t * (3.0 + n(seed + 1) * 2.0) + seed * 7) * 1.6
            let w = 3.4 - Double(i) * 0.4
            c.fill(tongue(bar, cx: fx, w: w, h: h, sway: sway),
                   with: .color(emberOrange.opacity(0.55 * bright)))
            c.fill(tongue(bar, cx: fx, w: w * 0.55, h: h * 0.6,
                          sway: sway * 0.7),
                   with: .color(flameYellow.opacity(0.7 * bright)))
        }
        sparks(&c, t, bar, tipX, count: 1 + Int(heat * 1.99))
    }

    private func tongue(_ bar: CGRect, cx: Double, w: Double, h: Double,
                        sway: Double) -> Path {
        Path { p in
            let baseY = bar.midY + 1
            p.move(to: CGPoint(x: cx - w / 2, y: baseY))
            p.addQuadCurve(
                to: CGPoint(x: cx + sway, y: baseY - h),
                control: CGPoint(x: cx - w / 2 + sway * 0.4,
                                 y: baseY - h * 0.55))
            p.addQuadCurve(
                to: CGPoint(x: cx + w / 2, y: baseY),
                control: CGPoint(x: cx + w / 2 + sway * 0.4,
                                 y: baseY - h * 0.55))
            p.closeSubpath()
        }
    }

    /// FFVII limit break — the whole fill runs hot: a scrolling heat
    /// gradient, a periodic shine sweep, a white-hot tip pulse.
    private func limit(_ c: inout GraphicsContext, _ t: Double,
                       _ bar: CGRect, _ tipX: Double) {
        let fill = CGRect(x: 0, y: bar.minY, width: tipX, height: bar.height)
        // In-bar parts clip to the capsule; the tip halo stays outside.
        var hot = c
        hot.clip(to: Path(roundedRect: bar, cornerRadius: bar.height / 2))
        hot.blendMode = .plusLighter
        // Scrolling heat band (red ends clamp, so the wrap is seamless).
        let phase = fract(t * (0.35 + 0.65 * heat))
        let L = max(24, fill.width)
        let x0 = (phase * 2 - 1) * L
        hot.fill(Path(fill), with: .linearGradient(
            Gradient(stops: [
                .init(color: Color(red: 0.9, green: 0.1, blue: 0.05)
                    .opacity(0.25 * bright), location: 0),
                .init(color: emberOrange.opacity(0.5 * bright), location: 0.35),
                .init(color: flameYellow.opacity(0.7 * bright), location: 0.5),
                .init(color: emberOrange.opacity(0.5 * bright), location: 0.65),
                .init(color: Color(red: 0.9, green: 0.1, blue: 0.05)
                    .opacity(0.25 * bright), location: 1),
            ]),
            startPoint: CGPoint(x: x0, y: bar.midY),
            endPoint: CGPoint(x: x0 + L, y: bar.midY)))
        // Shine sweep, slanted like the pace stripe.
        let sph = fract(t * (0.4 + 0.5 * heat))
        let sx = (sph * 1.5 - 0.25) * fill.width
        let slant = bar.height * 0.35
        var shine = Path()
        shine.move(to: CGPoint(x: sx - 2 + slant, y: bar.minY))
        shine.addLine(to: CGPoint(x: sx + 2 + slant, y: bar.minY))
        shine.addLine(to: CGPoint(x: sx + 2 - slant, y: bar.maxY))
        shine.addLine(to: CGPoint(x: sx - 2 - slant, y: bar.maxY))
        shine.closeSubpath()
        hot.fill(shine, with: .color(coreWhite.opacity(0.55 * bright)))
        // White-hot pulse at the tip — the halo that escapes the bar.
        let pr = (1.6 + 2.2 * heat) * (0.8 + 0.2 * sin(t * 7))
        let center = CGPoint(x: tipX, y: bar.midY)
        c.fill(Path(ellipseIn: CGRect(x: center.x - pr, y: center.y - pr,
                                      width: pr * 2, height: pr * 2)),
               with: .radialGradient(
                   Gradient(stops: [
                       .init(color: coreWhite.opacity(0.85 * bright), location: 0),
                       .init(color: flameYellow.opacity(0), location: 1),
                   ]),
                   center: center, startRadius: 0, endRadius: pr))
    }
}
