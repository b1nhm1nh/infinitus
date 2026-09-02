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
public struct GaugeBar: View {
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
    /// Cool glow 0…1 (behind pace, GaugeMath.chillDepth) — the burn's
    /// inverse: reserve breathes a slow mint halo. Mutually exclusive
    /// with burnHeat by construction (aheadOfPace true vs false).
    var chill: Double = 0
    /// Where the HP-drop zoom grows from. Columns near the popup's
    /// right edge (weekly/spend/scoped on the wide grid) anchor
    /// center or trailing so the 5× bar stays inside the window
    /// (user 2026-08-31: "fable drop: overflown hidden as fable is
    /// far right of window — happens only on list").
    var dropAnchor: UnitPoint = .leading
    /// All Lucky 7s: the call site decides the trigger; the label
    /// flashes the fever digits instead of the plain percent.
    var lucky: Bool = false
    @ScaledMetric(relativeTo: .caption) private var barWidth = 56.0
    @ScaledMetric(relativeTo: .caption) private var barHeight = 6.0
    @State private var shown: Double = 0
    // HP-drop drama (user 2026-08-31): a big one-refresh plunge zooms
    // the bar 5×, flashes the doomed chunk, then drains it. dropSeq
    // invalidates the pending closures when a newer change lands.
    @State private var dropTo: Double? = nil
    @State private var dropZoom = false
    @State private var cutFlash = false
    @State private var dropSeq = 0
    /// Killing blow: a drop that drains the bar to zero bursts shards
    /// and shakes at full zoom (user 2026-08-31).
    @State private var killTick = 0
    // Ahead-of-pace effects hold until the intro fill has landed
    // (user 2026-08-31: "ahead effect: should only starts when intro
    // ended") — a burn riding the bar WHILE it fills from empty reads
    // as a glitch, not drama. Armed by playFill's timer; seq-guarded
    // like the drop closures.
    @State private var burnArmed = false
    @State private var burnArmSeq = 0
    /// A one-refresh plunge of 10+ remaining-points is a dramatic burn.
    /// 60+ is a data correction, not a burn (an account/window swap —
    /// and the debug pane's refill demo hops 100→8 on its way to the
    /// spring refill; theatre there would fight the refill animation).
    private static let dropMin = 10.0
    private static let dropMax = 60.0
    // Intro choreography inputs (default 0 outside the popup — the
    // settings playground keeps its instant behavior).
    @Environment(\.introTick) private var introTick
    @Environment(\.introBarDelay) private var introBarDelay

    public init(remaining: Double, color: Color, paceRemaining: Double? = nil,
                dividers: [Double] = [], animated: Bool = true,
                burnStyle: String = "off", burnHeat: Double = 0,
                chill: Double = 0, dropAnchor: UnitPoint = .leading,
                lucky: Bool = false) {
        self.remaining = remaining
        self.color = color
        self.paceRemaining = paceRemaining
        self.dividers = dividers
        self.animated = animated
        self.burnStyle = burnStyle
        self.burnHeat = burnHeat
        self.chill = chill
        self.dropAnchor = dropAnchor
        self.lucky = lucky
    }

    public var body: some View {
        HStack(spacing: 3) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.22))
                // Fill animates via frame width (Canvas can't animate).
                Capsule().fill(color)
                    .frame(width: max(0, barWidth * min(100, max(0, shown)) / 100))
                // The doomed chunk: from the drop floor to the live fill
                // edge — derived from `shown`, so the filldown eats it in
                // perfect sync with the fill (no separate choreography).
                if let to = dropTo {
                    let x0 = barWidth * min(100, max(0, to)) / 100
                    let x1 = barWidth * min(100, max(0, shown)) / 100
                    Rectangle().fill(.white)
                        .frame(width: max(0, x1 - x0))
                        .offset(x: x0)
                        .opacity(cutFlash ? 0.95 : 0.35)
                }
                overlayMarks
            }
            .frame(width: barWidth, height: barHeight)
            .clipShape(Capsule())
            // Unclipped overlay so flames lick a few points above the
            // capsule; BurnOverlay caps its own rise (grid rows sit
            // close above). Gated here so the TimelineView inside
            // doesn't exist — and costs nothing — on calm bars.
            .overlay(alignment: .bottom) {
                if animated, burnArmed, burnHeat > 0, burnStyle != "off" {
                    BurnOverlay(style: burnStyle, heat: burnHeat,
                                fillFraction: min(100, max(0, shown)) / 100,
                                barWidth: barWidth, barHeight: barHeight)
                }
            }
            // Heat halo (user 2026-08-31: "bar with few left the
            // effects on remaining is too subtle"): the burn rides the
            // FILL, which nearly vanishes near empty — a heat-tinted
            // glowing border on the whole capsule keeps ahead-of-pace
            // readable at any fill. Ember orange -> core white as heat
            // climbs (BurnOverlay's palette).
            .overlay {
                if animated, burnArmed, burnHeat > 0, burnStyle != "off" {
                    let tint = Color(red: 1,
                                     green: 0.45 + 0.51 * burnHeat,
                                     blue: 0.10 + 0.75 * burnHeat)
                    Capsule()
                        .strokeBorder(tint.opacity(0.4 + 0.5 * burnHeat),
                                      lineWidth: 1)
                        .shadow(color: tint.opacity(0.5 + 0.5 * burnHeat),
                                radius: 2 + 5 * burnHeat)
                        .allowsHitTesting(false)
                }
            }
            // Cool halo (todo 2026-09-01: "effects to accounts that are
            // behind in usage"): the heat halo's inverse — usage running
            // behind the clock breathes a slow mint glow. Deliberately
            // calmer than the burn: reserve is good news, not drama.
            .overlay {
                if animated, burnArmed, chill > 0, burnStyle != "off" {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                        let phase = (sin(ctx.date.timeIntervalSinceReferenceDate
                                         * 2 * .pi / 2.4) + 1) / 2
                        // Deep breath: mostly-off at the trough so the
                        // pulse reads as motion, not a painted border.
                        let strength = (0.35 + 0.65 * chill) * (0.15 + 0.85 * phase)
                        let tint = Color(red: 0.35, green: 0.95, blue: 0.75)
                        Capsule()
                            .strokeBorder(tint.opacity(0.85 * strength),
                                          lineWidth: 1)
                            .shadow(color: tint.opacity(strength),
                                    radius: 2 + 5 * strength)
                    }
                    .allowsHitTesting(false)
                }
            }
            // Shard burst on a killing blow — above the bar, zooming
            // with it.
            .overlay {
                KillBurst(tick: killTick)
                    .frame(width: barWidth * 1.8, height: 44)
            }
            // The kill shake: hard jitter, zoomed.
            .keyframeAnimator(initialValue: 0.0, trigger: killTick) { view, x in
                view.offset(x: x)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(0.001, duration: 0.001)
                    CubicKeyframe(-2.5, duration: 0.05)
                    CubicKeyframe(2.5, duration: 0.05)
                    CubicKeyframe(-2, duration: 0.05)
                    CubicKeyframe(1.5, duration: 0.05)
                    CubicKeyframe(0, duration: 0.08)
                }
            }
            // The HP-drop zoom — after the burn overlay so flames zoom
            // with the bar. Overlapping neighbor rows is the drama.
            .scaleEffect(dropZoom ? 5 : 1, anchor: dropAnchor)
            .zIndex(dropZoom ? 10 : 0)

            if lucky, animated {
                LuckySevens(text: "\(Int(remaining))%")
            } else {
                Text("\(Int(remaining))%")
                    .font(.caption).monospacedDigit()
                    .contentTransition(animated ? .numericText(value: remaining)
                                                : .identity)
                    .foregroundStyle(remaining <= 0 ? Color.red : color.opacity(0.9))
            }
        }
        .onAppear { animated ? playFill() : (shown = remaining) }
        // Replay intro re-runs the fill too (it was missing from the
        // debug pane's Replay, user 2026-08-30).
        .onChange(of: introTick) { _, _ in playFill() }
        .onChange(of: remaining) { old, new in
            // Every change invalidates a running drop sequence AND resets
            // its visuals unconditionally — restoration must never live
            // only in a cancellable closure (or the bar sticks at 5×).
            dropSeq += 1
            if dropZoom || dropTo != nil {
                withAnimation(.easeOut(duration: 0.2)) { dropZoom = false }
                dropTo = nil
                cutFlash = false
            }
            // A jump UP of 25+ points is a window reset: replay the refill
            // from empty (the restore animation, user 2026-08-30).
            if new - old > 25 {
                // Visibly fill: sit empty a beat, then a slow spring
                // ("runs too fast", user 2026-08-30 playground test).
                shown = 0
                withAnimation(.spring(duration: 1.8, bounce: 0.2).delay(0.25)) {
                    shown = new
                }
            } else if old - new >= Self.dropMin,
                      old - new <= Self.dropMax || new <= 0.5,
                      animated {
                // A drop past dropMax still plays when it KILLS — a
                // 63-point killing blow is the drama, not a data
                // correction.
                playDrop(to: new)
            } else {
                withAnimation(.easeOut(duration: 0.5)) { shown = new }
            }
        }
    }

    /// The HP-drop sequence (user 2026-08-31): zoom the bar 5× in
    /// place, flash the chunk about to be lost, then drain it with an
    /// easeIn filldown and settle back to size.
    private func playDrop(to: Double) {
        let seq = dropSeq
        dropTo = to                       // chunk = [to, shown]; hold at old
        withAnimation(.spring(duration: 0.3, bounce: 0.45)) { dropZoom = true }
        withAnimation(.easeInOut(duration: 0.11)
            .repeatCount(7, autoreverses: true).delay(0.25)) { cutFlash = true }
        let kill = to <= 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) {
            guard seq == dropSeq else { return }
            withAnimation(.easeIn(duration: 0.5)) { shown = to }
            if kill {
                // The finisher lands as the drain hits bottom: shards
                // fly, the bar shakes, the zoom lingers on the corpse.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    guard seq == dropSeq else { return }
                    killTick += 1
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (kill ? 1.6 : 0.75)) {
                guard seq == dropSeq else { return }
                withAnimation(.spring(duration: 0.4)) { dropZoom = false }
                dropTo = nil
                cutFlash = false
            }
        }
    }

    /// The intro fill-up: from empty, held until the popup's content
    /// entrance has landed (introBarDelay; 0 outside the popup).
    private func playFill() {
        shown = 0
        burnArmed = false
        burnArmSeq += 1
        let seq = burnArmSeq
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.25 + introBarDelay + 1.6) {
            guard seq == burnArmSeq else { return }
            burnArmed = true
        }
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
    public var introTick: Int {
        get { self[IntroTickKey.self] }
        set { self[IntroTickKey.self] = newValue }
    }
    public var introBarDelay: Double {
        get { self[IntroBarDelayKey.self] }
        set { self[IntroBarDelayKey.self] = newValue }
    }
}
