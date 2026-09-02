import SwiftUI

/// Pace-fire overlays for GaugeBar: when a window burns faster than
/// time passes, its bar catches fire (user 2026-08-31 — "flaming or
/// FFVII limit break", then "need flaming effects, full bar effects").
/// Three auditionable styles; `heat` 0…1 (GaugeMath.burnHeat — +30
/// points ahead saturates) scales COVERAGE as well as size, count,
/// speed and brightness: low heat burns near the fill tip, heat ≈ 1
/// sets the whole fill ablaze.
///
/// TimelineView exists ONLY while something burns (the caller gates on
/// heat > 0 and style) so idle popups pay nothing. Capped at 20 fps:
/// the ember gradients and the limit marquee redraw a Canvas per frame,
/// and at display rate an RPG popup idled at ~25% CPU (#18, measured
/// 2026-09-03: rpg+burn 39% → capped 2-3%). The limit style is a
/// stepped PSX palette flip anyway; ember/flame flicker reads the same.
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
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { ctx in
            Canvas { c, size in
                guard fillFraction > 0.03, heat > 0 else { return }
                let t = ctx.date.timeIntervalSinceReferenceDate
                let bar = CGRect(x: 0, y: rise, width: size.width,
                                 height: size.height - rise)
                let tipX = bar.width * fillFraction
                // The WHOLE fill burns at any heat (user 2026-08-31,
                // twice: limit round then "amber effect still looking
                // missing left parts of bar") — heat drives intensity,
                // count and speed, never span.
                let x0 = 0.0
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
                    // A real floor at the left edge — a 0-opacity start
                    // read as "missing left parts" (user screenshot).
                    .init(color: emberOrange.opacity(0.30 * bright * pulse),
                          location: 0),
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

    /// FFVII limit break — the PSX gauge, faithfully (user 2026-08-31:
    /// "pixel perfect & animation fidelity with FFVII"). No gradients,
    /// no anti-aliasing, no alpha ramps: chunky 2pt pixels in hard
    /// palette bands. The burning region runs the classic tip-ward
    /// palette marquee (one white shine head per cycle), the whole
    /// band blinks in stepped palette-swap pulses (a frame flip, not a
    /// sine) and the fill tip runs white-hot. Everything stays INSIDE
    /// the capsule — the FFVII gauge floats nothing above itself.
    private func limit(_ c: inout GraphicsContext, _ t: Double,
                       _ bar: CGRect, _ x0: Double, _ tipX: Double) {
        let px = 2.0                                  // the "pixel"
        func q(_ v: Double) -> Double { (v / px).rounded(.down) * px }
        let hot2 = 0.6 + 0.4 * heat
        // Stepped palette-swap blink: PSX pulsing was a frame flip.
        let blink = fract(t * (1.4 + 1.6 * heat)) < 0.5 ? 1.0 : 0.72
        // The FFVII full-gauge shimmer is a RAINBOW marquee (user
        // 2026-08-31 screenshot note) — one hard band per hue plus the
        // white shine head, cycling end to end.
        let palette: [Color] = [
            Color(red: 1.00, green: 0.20, blue: 0.20),   // red
            Color(red: 1.00, green: 0.60, blue: 0.10),   // orange
            Color(red: 1.00, green: 0.95, blue: 0.20),   // yellow
            Color(red: 0.30, green: 1.00, blue: 0.35),   // green
            Color(red: 0.25, green: 0.90, blue: 1.00),   // cyan
            Color(red: 0.35, green: 0.45, blue: 1.00),   // blue
            Color(red: 0.85, green: 0.40, blue: 1.00),   // violet
            coreWhite,                                   // shine head
        ]
        let cellsPerBand = 2
        let cycle = palette.count * cellsPerBand      // 16 cells = 32pt
        var hot = c
        hot.clip(to: Path(roundedRect: bar, cornerRadius: bar.height / 2))
        // Column marquee across the WHOLE fill — the FFVII gauge
        // shimmers end to end (user screenshot: 'effect not filling
        // all bar'); heat drives speed and brightness, not span. The
        // loop wraps seamlessly because the palette does.
        let scroll = Int(fract(t / (1.1 - 0.5 * heat)) * Double(cycle))
        let c1 = Int((tipX / px).rounded(.up))
        for col in 0..<max(1, c1) {
            let idx = ((col - scroll) % cycle + cycle) % cycle
            let color = palette[idx / cellsPerBand]
            hot.fill(Path(CGRect(x: Double(col) * px, y: bar.minY,
                                 width: px, height: bar.height)),
                     with: .color(color.opacity(0.85 * hot2 * blink)))
        }
        // White-hot tip: the leading pixel columns flip harder.
        let tipFlip = fract(t * 6) < 0.5 ? 1.0 : 0.6
        for j in 1...2 {
            let x = q(tipX) - Double(j) * px
            guard x >= 0 else { break }
            hot.fill(Path(CGRect(x: x, y: bar.minY,
                                 width: px, height: bar.height)),
                     with: .color(coreWhite.opacity(0.95 * hot2 * tipFlip)))
        }
    }
}

/// The killing-blow finisher (user 2026-08-31: "a dramatic dead effect
/// if any kind of drops kill"): when an HP drop drains a bar to ZERO,
/// shards burst off it — ember and ash flying radially with a little
/// gravity — while GaugeBar shakes the bar at full zoom. One-shot,
/// deterministic seeds, exists only for ~0.9s per kill.
struct KillBurst: View {
    let tick: Int
    @State private var start: Date?
    /// The TimelineView exists only during the 0.9s burst: an always-on
    /// .animation timeline on EVERY bar re-rendered the row tree at
    /// display rate for nothing (#18).
    @State private var live = false

    var body: some View {
        Group {
            if live {
                burst
            } else {
                Color.clear
            }
        }
        .onChange(of: tick) { _, _ in
            start = Date()
            live = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { live = false }
        }
        .allowsHitTesting(false)
    }

    private var burst: some View {
        TimelineView(.animation) { ctx in
            Canvas { c, size in
                guard let start else { return }
                let t = ctx.date.timeIntervalSince(start)
                guard t >= 0, t < 0.9 else { return }
                let cx = size.width / 2
                let cy = size.height / 2
                for i in 0..<20 {
                    let seed = Double(i) * 3.19
                    let ang = n(seed) * .pi * 2
                    let v = 28 + n(seed + 1) * 60
                    let x = cx + cos(ang) * v * t
                    let y = cy + sin(ang) * v * t * 0.55 + 46 * t * t
                    let fade = max(0, 1 - t / 0.9)
                    let r = (1.1 + n(seed + 2) * 1.7) * fade
                    let color: Color = i % 3 == 0
                        ? Color(red: 1.00, green: 0.96, blue: 0.85)
                        : i % 2 == 0
                        ? Color(red: 1.00, green: 0.45, blue: 0.10)
                        : Color(red: 0.90, green: 0.12, blue: 0.08)
                    c.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r,
                                                  width: r * 2, height: r * 2)),
                           with: .color(color.opacity(fade)))
                }
            }
        }
    }

    private func n(_ i: Double) -> Double {
        let v = sin(i * 12.9898) * 43758.5453
        return v - v.rounded(.down)
    }
}
