import SwiftUI

/// Pace-fire overlays for GaugeBar: when a window burns faster than
/// time passes, its bar catches fire (user 2026-08-31 — "flaming or
/// FFVII limit break", then "need flaming effects, full bar effects").
/// Three auditionable styles; `heat` 0…1 (GaugeMath.burnHeat — +30
/// points ahead saturates) scales COVERAGE as well as size, count,
/// speed and brightness: low heat burns near the fill tip, heat ≈ 1
/// sets the whole fill ablaze.
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

    /// How far flames rise above the capsule. Tall on purpose — the
    /// first cut capped this at 6 and read as "not dramatic enough"
    /// (user 2026-08-31); overlapping the row above is accepted drama.
    private let rise: Double = 11

    var body: some View {
        TimelineView(.animation) { ctx in
            Canvas { c, size in
                guard fillFraction > 0.03, heat > 0 else { return }
                let t = ctx.date.timeIntervalSinceReferenceDate
                let bar = CGRect(x: 0, y: rise, width: size.width,
                                 height: size.height - rise)
                let tipX = bar.width * fillFraction
                // Burning region: from near the tip at low heat to the
                // whole fill at heat 1.
                let coverage = 0.3 + 0.7 * heat
                let x0 = tipX * (1 - coverage)
                switch style {
                case "ember": ember(&c, t, bar, x0, tipX)
                case "flame": flame(&c, t, bar, x0, tipX)
                case "limit": limit(&c, t, bar, x0, tipX)
                default: break
                }
            }
        }
        .frame(width: barWidth, height: barHeight + rise)
        .allowsHitTesting(false)
    }

    // MARK: shared bits

    private var bright: Double { 0.5 + 0.5 * heat }

    /// Deterministic hash noise 0…1 (replayable, unlike Double.random).
    private func n(_ i: Double) -> Double {
        let v = sin(i * 12.9898) * 43758.5453
        return v - v.rounded(.down)
    }
    private func fract(_ v: Double) -> Double { v - v.rounded(.down) }

    private let emberOrange = Color(red: 1.00, green: 0.45, blue: 0.10)
    private let flameYellow = Color(red: 1.00, green: 0.85, blue: 0.30)
    private let coreWhite   = Color(red: 1.00, green: 0.96, blue: 0.85)

    /// Sparks drifting up off the burning region.
    private func sparks(_ c: inout GraphicsContext, _ t: Double,
                        _ bar: CGRect, _ x0: Double, _ tipX: Double,
                        count: Int) {
        for i in 0..<count {
            let seed = Double(i) * 7.31
            let cycle = 0.8 + n(seed) * 0.9
            let ph = fract(t / cycle + n(seed + 1))
            let x = x0 + n(seed + 4) * max(1, tipX - x0)
                     + sin(t * (2.5 + n(seed + 2) * 2) + seed) * 2.5
            let y = bar.midY - ph * (bar.midY + 1)
            let r = 1.0 * (1 - ph * 0.6)
            c.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r,
                                          width: r * 2, height: r * 2)),
                   with: .color(flameYellow.opacity((1 - ph) * bright)))
        }
    }

    // MARK: styles

    /// Ember glow — the burning region smolders (gradient heat inside
    /// the fill), coals dotted through it, a big pulsing coal at the
    /// tip, sparks everywhere ("more flames and embers", user
    /// 2026-08-31 round 3).
    private func ember(_ c: inout GraphicsContext, _ t: Double,
                       _ bar: CGRect, _ x0: Double, _ tipX: Double) {
        var inBar = c
        inBar.clip(to: Path(roundedRect: bar, cornerRadius: bar.height / 2))
        let pulse = 0.8 + 0.2 * sin(t * 3.7 + sin(t * 6.1) * 0.8)
        inBar.fill(
            Path(CGRect(x: x0, y: bar.minY, width: tipX - x0,
                        height: bar.height)),
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: emberOrange.opacity(0), location: 0),
                    .init(color: emberOrange.opacity(0.6 * bright * pulse),
                          location: 0.55),
                    .init(color: flameYellow.opacity(0.8 * bright * pulse),
                          location: 1),
                ]),
                startPoint: CGPoint(x: x0, y: bar.midY),
                endPoint: CGPoint(x: tipX, y: bar.midY)))
        // Coals smoldering along the burning region (not just the tip).
        let coals = 2 + Int(heat * 3.99)
        for i in 0..<coals {
            let seed = Double(i) * 5.13
            let cx = x0 + (0.1 + 0.75 * n(seed)) * max(1, tipX - x0)
            let cFlick = 0.65 + 0.35 * sin(t * (3.5 + n(seed + 2) * 3)
                                           + seed * 9)
            let cr = (1.6 + 2.2 * heat) * cFlick
            let cc = CGPoint(x: cx, y: bar.midY)
            inBar.fill(
                Path(ellipseIn: CGRect(x: cc.x - cr, y: cc.y - cr,
                                       width: cr * 2, height: cr * 2)),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: flameYellow.opacity(0.85 * bright),
                              location: 0),
                        .init(color: emberOrange.opacity(0.5 * bright),
                              location: 0.5),
                        .init(color: emberOrange.opacity(0), location: 1),
                    ]),
                    center: cc, startRadius: 0, endRadius: cr))
        }
        let flick = 0.75 + 0.25 * sin(t * 5.5 + sin(t * 9.3) * 1.3)
        let r = (3.0 + 3.5 * heat) * flick
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
        sparks(&c, t, bar, x0, tipX, count: 6 + Int(heat * 9.99))
    }

    /// Flame licks — a dense wall of tongues across the WHOLE burning
    /// region, rising well above the bar, biggest at the tip.
    private func flame(_ c: inout GraphicsContext, _ t: Double,
                       _ bar: CGRect, _ x0: Double, _ tipX: Double) {
        let span = max(1, tipX - x0)
        let count = max(5, min(18, Int(span / 3.5) + 1))
        for i in 0..<count {
            let seed = Double(i) * 3.77
            let fx = tipX - span * Double(i) / Double(count) - n(seed + 5) * 2
            // Slight falloff away from the tip; every tongue stays big.
            let falloff = 1.0 - 0.35 * Double(i) / Double(max(1, count - 1))
            let hFlick = 0.6 + 0.4 * sin(t * (4.0 + n(seed) * 3.5) + seed * 11)
            let h = (3.0 + (rise - 1.5) * heat * falloff) * hFlick
            let sway = sin(t * (2.6 + n(seed + 1) * 2.2) + seed * 7) * 2.2
            let w = 3.8 - 1.2 * Double(i) / Double(max(1, count - 1))
            c.fill(tongue(bar, cx: fx, w: w, h: h, sway: sway),
                   with: .color(emberOrange.opacity(0.6 * bright)))
            c.fill(tongue(bar, cx: fx, w: w * 0.55, h: h * 0.6,
                          sway: sway * 0.7),
                   with: .color(flameYellow.opacity(0.75 * bright)))
        }
        sparks(&c, t, bar, x0, tipX, count: 6 + Int(heat * 7.99))
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

    /// FFVII limit break — the fill runs white hot: a fast scrolling
    /// heat gradient, a shine sweep, a heat-haze glow rising off the
    /// whole burning region, a blazing tip.
    private func limit(_ c: inout GraphicsContext, _ t: Double,
                       _ bar: CGRect, _ x0: Double, _ tipX: Double) {
        let hot2 = 0.6 + 0.4 * heat
        let fill = CGRect(x: 0, y: bar.minY, width: tipX, height: bar.height)
        // In-bar parts clip to the capsule; halo and haze stay outside.
        var hot = c
        hot.clip(to: Path(roundedRect: bar, cornerRadius: bar.height / 2))
        hot.blendMode = .plusLighter
        // Scrolling heat band (red ends clamp, so the wrap is seamless).
        let phase = fract(t * (0.6 + 1.0 * heat))
        let L = max(24, fill.width)
        let bx0 = (phase * 2 - 1) * L
        hot.fill(Path(fill), with: .linearGradient(
            Gradient(stops: [
                .init(color: Color(red: 0.9, green: 0.1, blue: 0.05)
                    .opacity(0.35 * hot2), location: 0),
                .init(color: emberOrange.opacity(0.65 * hot2), location: 0.35),
                .init(color: flameYellow.opacity(0.9 * hot2), location: 0.5),
                .init(color: emberOrange.opacity(0.65 * hot2), location: 0.65),
                .init(color: Color(red: 0.9, green: 0.1, blue: 0.05)
                    .opacity(0.35 * hot2), location: 1),
            ]),
            startPoint: CGPoint(x: bx0, y: bar.midY),
            endPoint: CGPoint(x: bx0 + L, y: bar.midY)))
        // Shine sweep, slanted like the pace stripe.
        let sph = fract(t * (0.5 + 0.6 * heat))
        let sx = (sph * 1.5 - 0.25) * fill.width
        let slant = bar.height * 0.35
        var shine = Path()
        shine.move(to: CGPoint(x: sx - 3 + slant, y: bar.minY))
        shine.addLine(to: CGPoint(x: sx + 3 + slant, y: bar.minY))
        shine.addLine(to: CGPoint(x: sx + 3 - slant, y: bar.maxY))
        shine.addLine(to: CGPoint(x: sx - 3 - slant, y: bar.maxY))
        shine.closeSubpath()
        hot.fill(shine, with: .color(coreWhite.opacity(0.7 * hot2)))
        // Heat haze rising off the whole burning region.
        let hazePulse = 0.75 + 0.25 * sin(t * 5.1)
        c.fill(Path(CGRect(x: x0, y: 0, width: tipX - x0, height: rise)),
               with: .linearGradient(
                   Gradient(stops: [
                       .init(color: emberOrange.opacity(0), location: 0),
                       .init(color: emberOrange.opacity(0.45 * hot2 * hazePulse),
                             location: 1),
                   ]),
                   startPoint: CGPoint(x: x0, y: 0),
                   endPoint: CGPoint(x: x0, y: rise)))
        // Blazing tip halo.
        let pr = (2.5 + 3.5 * heat) * (0.8 + 0.2 * sin(t * 7))
        let center = CGPoint(x: tipX, y: bar.midY)
        c.fill(Path(ellipseIn: CGRect(x: center.x - pr, y: center.y - pr,
                                      width: pr * 2, height: pr * 2)),
               with: .radialGradient(
                   Gradient(stops: [
                       .init(color: coreWhite.opacity(0.9 * hot2), location: 0),
                       .init(color: flameYellow.opacity(0), location: 1),
                   ]),
                   center: center, startRadius: 0, endRadius: pr))
        // Embers flying off the white-hot bar.
        sparks(&c, t, bar, x0, tipX, count: 5 + Int(heat * 7.99))
    }
}
