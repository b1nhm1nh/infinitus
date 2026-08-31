import SwiftUI
import CswapCore

/// The account-switch celebration: a bright sweep that runs across the row
/// plus a brief accent glow. Attach to the active row; fires whenever
/// `trigger` changes (AppModel bumps it on every observed switch).
struct SwitchFlash: ViewModifier {
    let trigger: Int
    var color: Color = .accentColor

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geo in
                    // keyframeAnimator restarts cleanly on every trigger
                    // bump — phaseAnimator would keep cycling forever.
                    let width = geo.size.width
                    Rectangle()
                        .fill(
                            // The shoulders carry the THEME color — with
                            // them at opacity 0 the band was pure white
                            // and every theme celebrated identically
                            // (user report 2026-08-30).
                            LinearGradient(
                                colors: [.clear,
                                         color.opacity(0.30),
                                         Color.white.opacity(0.35),
                                         color.opacity(0.30),
                                         .clear],
                                startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(width: max(60, width * 0.25))
                        .keyframeAnimator(
                            initialValue: -0.35,
                            trigger: trigger
                        ) { view, x in
                            view.offset(x: x * width)
                        } keyframes: { _ in
                            KeyframeTrack {
                                CubicKeyframe(-0.35, duration: 0.001)
                                CubicKeyframe(1.15, duration: 0.85)
                            }
                        }
                        .allowsHitTesting(false)
                }
                .clipped()
            }
            .keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, glow in
                // A translucent wash, not just a shadow: the Grid layout
                // hosts this on a CLEAR overlay rect, and a shadow of
                // transparent content is invisible.
                view
                    .overlay { color.opacity(glow * 0.15).allowsHitTesting(false) }
                    .shadow(color: color.opacity(glow),
                            radius: 8 * glow)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(0.9, duration: 0.25)
                    CubicKeyframe(0.0, duration: 0.9)
                }
            }
    }
}

/// Highlights the EXACT data point that changed: when `value` moves, the
/// view flashes a soft accent glow + brief brightness lift, right where
/// the number is. Attach to any cell showing live data.
struct ValueChangedGlow<V: Equatable>: ViewModifier {
    let value: V
    var color: Color = .accentColor
    @State private var tick = 0

    func body(content: Content) -> some View {
        content
            .onChange(of: value) { tick += 1 }
            .keyframeAnimator(initialValue: 0.0, trigger: tick) { view, glow in
                view
                    .shadow(color: color.opacity(glow), radius: 6 * glow)
                    .brightness(glow * 0.25)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(0.001, duration: 0.001)
                    CubicKeyframe(0.9, duration: 0.2)
                    CubicKeyframe(0.0, duration: 1.0)
                }
            }
    }
}

extension View {
    /// Theme-tinted celebration sweep (color from RowTheme.flashColor).
    func switchFlash(_ trigger: Int, color: Color = .accentColor) -> some View {
        modifier(SwitchFlash(trigger: trigger, color: color))
    }

    /// Glow in place whenever `value` changes.
    func glowOnChange<V: Equatable>(of value: V, color: Color = .accentColor) -> some View {
        modifier(ValueChangedGlow(value: value, color: color))
    }
}

/// The death beat — the switch celebration's grim mirror (user
/// 2026-08-30: "play dead animation too when account goes alive ->
/// dead"). A red hit that flickers while the row drains gray, then a
/// small slump that settles. On the wide Grid this wraps a clear
/// overlay band (saturation is a no-op there; the row's own
/// dead-restyle does the draining) — stacked cards wrap real content
/// and get the full drain.
struct DeathFlash: ViewModifier {
    let trigger: Int
    var color: Color = .red

    func body(content: Content) -> some View {
        content
            .keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, f in
                view
                    .saturation(1 - f)
                    .overlay { color.opacity(f * 0.22).allowsHitTesting(false) }
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(0.001, duration: 0.001)
                    CubicKeyframe(0.9, duration: 0.15)   // the hit
                    CubicKeyframe(0.35, duration: 0.15)  // flicker
                    CubicKeyframe(1.0, duration: 0.15)
                    CubicKeyframe(0.0, duration: 0.9)    // settle into gray
                }
            }
            .keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, y in
                view.offset(y: y)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(0.001, duration: 0.001)
                    CubicKeyframe(4, duration: 0.25)     // slump
                    SpringKeyframe(0, duration: 0.6, spring: .bouncy)
                }
            }
    }
}

extension View {
    /// Death beat; fires when `trigger` changes (0 = never armed).
    func deathFlash(_ trigger: Int, color: Color = .red) -> some View {
        modifier(DeathFlash(trigger: trigger, color: color))
    }
}

/// The revival fanfare — the death beat's bright mirror (user
/// 2026-08-31: "account revive needs dramatic full line revival
/// glowing effect"). A green surge washes the whole row while a wide
/// bright sweep runs its length, the row lifts out of the slump and
/// settles, and the glow breathes twice before fading. Overlay-first
/// like SwitchFlash, so the wide Grid's CLEAR band hosts it too
/// (brightness alone is a no-op on transparent content).
struct ReviveFlash: ViewModifier {
    let trigger: Int
    var color: Color = .green

    func body(content: Content) -> some View {
        content
            // Full-length sweep: wider and slower than the switch
            // celebration — a resurrection, not a handoff. Parked
            // outside the clipped bounds until triggered.
            .overlay {
                GeometryReader { geo in
                    let width = geo.size.width
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [.clear,
                                         color.opacity(0.45),
                                         Color.white.opacity(0.55),
                                         color.opacity(0.45),
                                         .clear],
                                startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(width: max(80, width * 0.35))
                        .keyframeAnimator(
                            initialValue: -0.5,
                            trigger: trigger
                        ) { view, x in
                            view.offset(x: x * width)
                        } keyframes: { _ in
                            KeyframeTrack {
                                CubicKeyframe(-0.5, duration: 0.001)
                                CubicKeyframe(1.2, duration: 1.1)
                            }
                        }
                        .allowsHitTesting(false)
                }
                .clipped()
            }
            .keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, glow in
                view
                    .overlay { color.opacity(glow * 0.28).allowsHitTesting(false) }
                    .shadow(color: color.opacity(glow), radius: 12 * glow)
                    .brightness(glow * 0.18)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(0.001, duration: 0.001)
                    CubicKeyframe(1.0, duration: 0.20)   // the surge
                    CubicKeyframe(0.45, duration: 0.30)  // breathe out
                    CubicKeyframe(0.9, duration: 0.30)   // second pulse
                    CubicKeyframe(0.0, duration: 1.2)    // glow fades
                }
            }
            // The anti-slump: rise and settle.
            .keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, y in
                view.offset(y: y)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(0.001, duration: 0.001)
                    CubicKeyframe(-4, duration: 0.25)    // lift
                    SpringKeyframe(0, duration: 0.7, spring: .bouncy)
                }
            }
    }
}

extension View {
    /// Revival fanfare; fires when `trigger` changes (0 = never armed).
    func reviveFlash(_ trigger: Int, color: Color = .green) -> some View {
        modifier(ReviveFlash(trigger: trigger, color: color))
    }
}

/// FFVII "All Lucky 7s" fever, done AUTHENTICALLY (user 2026-08-31
/// screenshot: Barret's menu entry): the character NAME wears a
/// per-letter rainbow whose colors travel along the text — a marquee,
/// not a blink — over a steady rainbow gradient band. Nothing flashes;
/// the original doesn't. Trigger (Fable at 77%, or 5h AND 7d both 77)
/// is decided at the call sites.
/// One shared trigger for the fever: Fable (any scoped window) showing
/// exactly 77 remaining, or the 5h AND 7d pair both at 77.
extension Account {
    var allLucky7s: Bool {
        if let five = usage?.fiveHour?.pct,
           let seven = usage?.sevenDay?.pct,
           Int(GaugeMath.remaining(usedPct: five)) == 77,
           Int(GaugeMath.remaining(usedPct: seven)) == 77 { return true }
        return (usage?.scoped ?? []).contains {
            Int(GaugeMath.remaining(usedPct: $0.pct)) == 77
        }
    }
}

/// The fever's FULL-ROW treatment (user 2026-08-31, refined: "not
/// flashing but border will loop in circle"): a steady hue-cycling
/// rainbow wash over the whole row, rimmed by a neon border whose
/// rainbow CHASES around the perimeter — a rotating angular gradient,
/// no blinking anywhere. Sits BEHIND content.
struct LuckyRowBackground: View {
    var cornerRadius: Double = 5

    private static let rainbow: [Color] = [
        Color(red: 1.0, green: 0.2, blue: 0.2),
        Color(red: 1.0, green: 0.6, blue: 0.1),
        Color(red: 1.0, green: 0.95, blue: 0.2),
        Color(red: 0.3, green: 1.0, blue: 0.35),
        Color(red: 0.25, green: 0.9, blue: 1.0),
        Color(red: 0.4, green: 0.45, blue: 1.0),
        Color(red: 0.85, green: 0.4, blue: 1.0),
        Color(red: 1.0, green: 0.2, blue: 0.2),
    ]

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let shape = RoundedRectangle(cornerRadius: cornerRadius)
            ZStack {
                // Steady wash; the slow hue cycle keeps it alive
                // without any brightness change (no flash).
                shape.fill(LinearGradient(colors: Self.rainbow,
                                          startPoint: .leading,
                                          endPoint: .trailing))
                    .opacity(0.18)
                    .hueRotation(.degrees(t * 40))
                // The neon border, Gemini-style (user 2026-08-31
                // screenshot): ONE luminous comet arc orbiting the
                // outline — a bright head with a soft blurred tail
                // fading behind it, hue drifting as it travels. Canvas
                // + trimmedPath; hard segments read as a picket fence.
                Canvas { c, size in
                    let rect = CGRect(origin: .zero, size: size)
                        .insetBy(dx: 1.5, dy: 1.5)
                    let path = Path(roundedRect: rect,
                                    cornerRadius: cornerRadius)
                    let phase = (t * 0.16).truncatingRemainder(dividingBy: 1)
                    let hue = (t * 0.06).truncatingRemainder(dividingBy: 1)
                    func seg(_ f0: Double, _ f1: Double, _ color: Color,
                             _ w: Double, _ ctx: GraphicsContext) {
                        let a = f0.truncatingRemainder(dividingBy: 1)
                        let b = a + (f1 - f0)
                        let style = StrokeStyle(lineWidth: w, lineCap: .round)
                        if b <= 1 {
                            ctx.stroke(path.trimmedPath(from: a, to: b),
                                       with: .color(color), style: style)
                        } else {
                            ctx.stroke(path.trimmedPath(from: a, to: 1),
                                       with: .color(color), style: style)
                            ctx.stroke(path.trimmedPath(from: 0, to: b - 1),
                                       with: .color(color), style: style)
                        }
                    }
                    let tailN = 14
                    let segLen = 0.012
                    // Soft outer glow pass, then the bright core.
                    var glow = c
                    glow.addFilter(.blur(radius: 4))
                    for k in 0..<tailN {
                        let fade = pow(1 - Double(k) / Double(tailN), 2)
                        let f0 = phase - Double(k + 1) * segLen
                        let color = Color(hue: (hue + Double(k) * 0.015)
                            .truncatingRemainder(dividingBy: 1),
                            saturation: 0.9, brightness: 1.0)
                        seg(f0 + 1, f0 + 1 + segLen,
                            color.opacity(0.8 * fade), 4.5, glow)
                    }
                    for k in 0..<tailN {
                        let fade = pow(1 - Double(k) / Double(tailN), 2)
                        let f0 = phase - Double(k + 1) * segLen
                        let color = Color(hue: (hue + Double(k) * 0.015)
                            .truncatingRemainder(dividingBy: 1),
                            saturation: 0.75, brightness: 1.0)
                        seg(f0 + 1, f0 + 1 + segLen,
                            color.opacity(fade), 1.8, c)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// The activating digits themselves (user 2026-08-31: "keep the
/// flashing 77 numbers that activated the effect"): the percent label
/// on a bar sitting at 77 flashes in hard frame steps — gold/white
/// like the 7777 damage pops, with a rainbow run.
struct LuckySevens: View {
    let text: String

    private static let steps: [Color] = [
        Color(red: 1.00, green: 0.85, blue: 0.20), .white,
        Color(red: 1.00, green: 0.85, blue: 0.20), .white,
        Color(red: 1.00, green: 0.25, blue: 0.25),
        Color(red: 1.00, green: 0.60, blue: 0.10),
        Color(red: 1.00, green: 0.95, blue: 0.20),
        Color(red: 0.30, green: 1.00, blue: 0.35),
        Color(red: 0.25, green: 0.90, blue: 1.00),
        Color(red: 0.85, green: 0.40, blue: 1.00),
    ]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.14)) { ctx in
            let frame = Int(ctx.date.timeIntervalSinceReferenceDate / 0.14)
            Text(text)
                .font(.caption).bold().monospacedDigit()
                .foregroundStyle(Self.steps[frame % Self.steps.count])
                .scaleEffect(frame % 2 == 0 ? 1.0 : 1.12)
        }
        .help("All Lucky 7s!")
    }
}

struct LuckyName: View {
    let text: String
    var font: Font = .body
    var bold = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.12)) { ctx in
            // Step, not smooth time: the PSX palette-cycles per frame.
            let step = Int(ctx.date.timeIntervalSinceReferenceDate / 0.12)
            Text(attributed(step))
                .font(font)
                .fontWeight(bold ? .bold : .regular)
        }
        .help("All Lucky 7s!")
    }

    private func attributed(_ step: Int) -> AttributedString {
        var out = AttributedString()
        for (i, ch) in text.enumerated() {
            var run = AttributedString(String(ch))
            // Colors travel letter-to-letter: index minus step.
            let hue = (Double(i) * 0.13 - Double(step) * 0.045)
                .truncatingRemainder(dividingBy: 1)
            run.foregroundColor = Color(
                hue: hue < 0 ? hue + 1 : hue,
                saturation: 0.85, brightness: 1.0)
            out += run
        }
        return out
    }
}

/// The "resetting…" pulse as a reusable modifier (debug pane demo).
private struct PulseOpacity: ViewModifier {
    func body(content: Content) -> some View {
        // .animation = every frame; the 0.05s periodic tick rendered a
        // choppy ~20fps pulse (user: "low laggy", 2026-08-30). Faster
        // sine too — reads as a flash, not a slow breath.
        TimelineView(.animation) { ctx in
            content.opacity(0.35 + 0.65 * abs(sin(
                ctx.date.timeIntervalSinceReferenceDate * 4.0)))
        }
    }
}

extension View {
    func pulseOpacity() -> some View { modifier(PulseOpacity()) }
}


// MARK: - Launch intro choreography (user script, 2026-08-30)
//
// app starts -> footer controls slide in (left group from the left,
// right group from the right) while the account content enters
// (dev-tunable: slide from top / bottom / fade, with speed) -> the
// bars play their fill-up and the active row flashes (GaugeBar
// onAppear + firstLoad switchFlashTick) -> the Infinitus title lands
// with an exaggerated flourish (several styles to audition).

struct IntroSlideIn: ViewModifier {
    @ObservedObject var model: AppModel
    let fromLeft: Bool
    @State private var on = true

    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0)
            .offset(x: on ? 0 : (fromLeft ? -70 : 70))
            // Hold hidden only while data is COMING. With no engine
            // installed nothing ever arrives — the onboarding card must
            // show, not an empty sliver (found live 2026-08-30).
            .onAppear {
                model.accounts.isEmpty && !model.engineMissing
                    ? (on = false) : play()
            }
            .onChange(of: model.introTick) { _, _ in play() }
    }

    private func play() {
        let speed = max(0.2, model.introSpeed)
        on = false
        withAnimation(.spring(duration: 0.6 / speed, bounce: 0.25)) {
            on = true
        }
    }
}

struct IntroContentReveal: ViewModifier {
    @ObservedObject var model: AppModel
    @State private var on = true

    /// "rows" hands the entrance to the per-row IntroRowSlide stagger —
    /// a container fade on top would just dim the sliding rows.
    private var delegated: Bool { model.introStyle == "rows" }

    func body(content: Content) -> some View {
        let dy: CGFloat = switch model.introStyle {
        case "top": -44
        case "bottom": 44
        default: 0
        }
        content
            .opacity(delegated || on ? 1 : 0)
            .offset(y: delegated || on ? 0 : dy)
            // Hold hidden only while data is COMING. With no engine
            // installed nothing ever arrives — the onboarding card must
            // show, not an empty sliver (found live 2026-08-30).
            .onAppear {
                model.accounts.isEmpty && !model.engineMissing
                    ? (on = false) : play()
            }
            .onChange(of: model.introTick) { _, _ in play() }
            .onChange(of: model.introStyle) { _, _ in play() }
    }

    private func play() {
        let speed = max(0.2, model.introSpeed)
        on = false
        withAnimation(.spring(duration: 0.7 / speed, bounce: 0.2)) {
            on = true
        }
    }
}

/// One account row's entrance for the "rows" content style: slide in
/// from the right, each row a beat after the one above (user
/// 2026-08-30). Inert for every other style. On the wide Grid the
/// modifier rides a Group INSIDE each GridRow — a Group distributes a
/// modifier to each child, so the row's cells move as one without
/// collapsing the GridRow (a modified GridRow is one cell).
struct IntroRowSlide: ViewModifier {
    @ObservedObject var model: AppModel
    let index: Int
    @State private var on = true

    private var active: Bool { model.introStyle == "rows" }

    func body(content: Content) -> some View {
        content
            .opacity(!active || on ? 1 : 0)
            .offset(x: !active || on ? 0 : 90)
            .onAppear {
                guard active else { return }
                model.accounts.isEmpty && !model.engineMissing
                    ? (on = false) : play()
            }
            .onChange(of: model.introTick) { _, _ in if active { play() } }
            .onChange(of: model.introStyle) { _, _ in
                if active { play() } else { on = true }
            }
    }

    private func play() {
        let speed = max(0.2, model.introSpeed)
        on = false
        withAnimation(.spring(duration: 0.55 / speed, bounce: 0.22)
            .delay(Double(index) * 0.09 / speed)) { on = true }
    }
}

/// The title's landing — deliberately exaggerated; styles to audition:
///  zoom  — grows from a dot with a big overshoot bounce
///  slam  — stamps down from 3.4x with a tilt, flash on impact
///  spin  — spins up two turns while growing
struct IntroTitleFlourish: ViewModifier {
    @ObservedObject var model: AppModel
    @State private var on = true
    @State private var glow = 0.0

    func body(content: Content) -> some View {
        content
            .scaleEffect(on ? 1 : startScale)
            .rotationEffect(.degrees(on ? 0 : startRotation))
            .opacity(on ? 1 : 0)
            .brightness(glow)
            // Hold hidden only while data is COMING. With no engine
            // installed nothing ever arrives — the onboarding card must
            // show, not an empty sliver (found live 2026-08-30).
            .onAppear {
                model.accounts.isEmpty && !model.engineMissing
                    ? (on = false) : play()
            }
            .onChange(of: model.introTick) { _, _ in play() }
            .onChange(of: model.introTitle) { _, _ in play() }
    }

    private var startScale: CGFloat {
        switch model.introTitle {
        case "slam": 3.4
        case "spin", "zoom": 0.1
        default: 1
        }
    }

    private var startRotation: Double {
        switch model.introTitle {
        case "slam": -12
        case "spin": -720
        default: 0
        }
    }

    private func play() {
        guard model.introTitle != "off" else { on = true; return }
        let speed = max(0.2, model.introSpeed)
        on = false
        glow = 0
        // Lands while the bars' fill-up is under way — anchored to the
        // same introBarDelay gate as the bars themselves.
        let delay = model.introBarDelay + 0.9 / speed
        let anim: Animation = switch model.introTitle {
        case "slam": .spring(duration: 0.5 / speed, bounce: 0.35)
        case "spin": .spring(duration: 0.9 / speed, bounce: 0.3)
        default: .spring(duration: 0.7 / speed, bounce: 0.55)
        }
        withAnimation(anim.delay(delay)) { on = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.15) {
            glow = 0.8
            withAnimation(.easeOut(duration: 0.8 / speed)) { glow = 0 }
        }
    }
}

extension View {
    func introSlide(_ model: AppModel, fromLeft: Bool) -> some View {
        modifier(IntroSlideIn(model: model, fromLeft: fromLeft))
    }
    func introContent(_ model: AppModel) -> some View {
        modifier(IntroContentReveal(model: model))
    }
    func introRow(_ model: AppModel, index: Int) -> some View {
        modifier(IntroRowSlide(model: model, index: index))
    }
    func introTitle(_ model: AppModel) -> some View {
        modifier(IntroTitleFlourish(model: model))
    }
}
