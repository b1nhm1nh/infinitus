import SwiftUI

/// CodexBar-faithful usage bar (steipete/CodexBar UsageProgressBar.swift,
/// studied 2026-08-30 at user request), themed:
///  - continuous capsule track + remaining fill
///  - boundary ticks dividing it into small segments (day marks on a
///    weekly bar, hour marks on a session bar — the "smaller bars" look)
///  - a slanted pace stripe where the burn SHOULD be (green = reserve,
///    red = deficit), punched through the fill
///  - a warning marker near empty
///  - the fill ANIMATES; a big refill (window reset) springs full.
struct GaugeBar: View {
    let remaining: Double
    let color: Color
    var paceRemaining: Double? = nil
    /// Boundary ticks (0-100, remaining axis) — day/hour segment marks.
    var dividers: [Double] = []
    /// False in the settings theme previews: the numericText roll never
    /// resolves inside the card's horizontal ScrollView (macOS 26 —
    /// percent labels froze mid-roll as ":" slivers, user screenshot
    /// 2026-08-30) and the intro fill has nothing to choreograph there.
    var animated: Bool = true
    /// Pace fire ("off"/"ember"/"flame"/"limit") + heat 0…1 (how far
    /// ahead of pace, GaugeMath.burnHeat) — 7d/model bars burn when
    /// usage outruns the clock (user 2026-08-31).
    var burnStyle: String = "off"
    var burnHeat: Double = 0
    @ScaledMetric(relativeTo: .caption) private var barWidth = 56.0
    @ScaledMetric(relativeTo: .caption) private var barHeight = 6.0
    @State private var shown: Double = 0
    // Intro choreography inputs (default 0 outside the popup — the
    // settings playground keeps its instant behavior).
    @Environment(\.introTick) private var introTick
    @Environment(\.introBarDelay) private var introBarDelay

    var body: some View {
        HStack(spacing: 3) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.22))
                // Fill animates via frame width (Canvas can't animate).
                Capsule().fill(color)
                    .frame(width: max(0, barWidth * min(100, max(0, shown)) / 100))
                overlayMarks
            }
            .frame(width: barWidth, height: barHeight)
            .clipShape(Capsule())
            // Unclipped overlay so flames lick a few points above the
            // capsule; BurnOverlay caps its own rise (grid rows sit
            // close above). Gated here so the TimelineView inside
            // doesn't exist — and costs nothing — on calm bars.
            .overlay(alignment: .bottom) {
                if animated, burnHeat > 0, burnStyle != "off" {
                    BurnOverlay(style: burnStyle, heat: burnHeat,
                                fillFraction: min(100, max(0, shown)) / 100,
                                barWidth: barWidth, barHeight: barHeight)
                }
            }

            Text("\(Int(remaining))%")
                .font(.caption).monospacedDigit()
                .contentTransition(animated ? .numericText(value: remaining)
                                            : .identity)
                .foregroundStyle(remaining <= 0 ? Color.red : color.opacity(0.9))
        }
        .onAppear { animated ? playFill() : (shown = remaining) }
        // Replay intro re-runs the fill too (it was missing from the
        // debug pane's Replay, user 2026-08-30).
        .onChange(of: introTick) { _, _ in playFill() }
        .onChange(of: remaining) { old, new in
            // A jump UP of 25+ points is a window reset: replay the refill
            // from empty (the restore animation, user 2026-08-30).
            if new - old > 25 {
                // Visibly fill: sit empty a beat, then a slow spring
                // ("runs too fast", user 2026-08-30 playground test).
                shown = 0
                withAnimation(.spring(duration: 1.8, bounce: 0.2).delay(0.25)) {
                    shown = new
                }
            } else {
                withAnimation(.easeOut(duration: 0.5)) { shown = new }
            }
        }
    }

    /// The intro fill-up: from empty, held until the popup's content
    /// entrance has landed (introBarDelay; 0 outside the popup).
    private func playFill() {
        shown = 0
        withAnimation(.spring(duration: 1.8, bounce: 0.2)
            .delay(0.25 + introBarDelay)) {
            shown = remaining
        }
    }

    /// Ticks + pace stripe + warning mark, drawn over fill and track.
    private var overlayMarks: some View {
        Canvas { context, size in
            // Segment boundary ticks (CodexBar workday markers): thin
            // primary lines from the bottom, subtle.
            for d in dividers where d > 1 && d < 99 {
                let x = size.width * d / 100
                context.fill(
                    Path(CGRect(x: x - 0.5, y: size.height * 0.35,
                                width: 1, height: size.height * 0.65)),
                    with: .color(.black.opacity(0.5)))
            }
            // Warning marker near empty (CodexBar quota warning): a
            // fixed tick at 10% remaining, red-tinted.
            let warnX = size.width * 0.10
            context.fill(
                Path(CGRect(x: warnX - 0.75, y: 0, width: 1.5,
                            height: size.height)),
                with: .color(.red.opacity(remaining <= 12 ? 0.9 : 0.45)))
            // Pace stripe: slanted double-tick, green ahead / red behind.
            if let pace = paceRemaining {
                let clamped = min(100, max(0, pace))
                let x = size.width * clamped / 100
                let slant = size.height * 0.35
                func stripe(_ cx: CGFloat, _ w: CGFloat) -> Path {
                    Path { p in
                        p.move(to: CGPoint(x: cx - w / 2 + slant, y: 0))
                        p.addLine(to: CGPoint(x: cx + w / 2 + slant, y: 0))
                        p.addLine(to: CGPoint(x: cx + w / 2 - slant, y: size.height))
                        p.addLine(to: CGPoint(x: cx - w / 2 - slant, y: size.height))
                        p.closeSubpath()
                    }
                }
                context.blendMode = .destinationOut
                context.fill(stripe(x, 5), with: .color(.white.opacity(0.9)))
                context.blendMode = .normal
                let deficit = remaining < clamped
                context.fill(stripe(x, 1.8),
                             with: .color(deficit ? .red : .green))
            }
        }
    }
}


// MARK: Intro environment plumbing — set once on MenuContent, read by
// every bar (GaugeBar takes no model).
private struct IntroTickKey: EnvironmentKey {
    static let defaultValue = 0
}
private struct IntroBarDelayKey: EnvironmentKey {
    static let defaultValue = 0.0
}
extension EnvironmentValues {
    var introTick: Int {
        get { self[IntroTickKey.self] }
        set { self[IntroTickKey.self] = newValue }
    }
    var introBarDelay: Double {
        get { self[IntroBarDelayKey.self] }
        set { self[IntroBarDelayKey.self] = newValue }
    }
}
