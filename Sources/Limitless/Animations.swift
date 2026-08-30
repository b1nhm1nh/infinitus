import SwiftUI

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

/// The "resetting…" pulse as a reusable modifier (debug pane demo).
private struct PulseOpacity: ViewModifier {
    func body(content: Content) -> some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
            content.opacity(0.35 + 0.65 * abs(sin(
                ctx.date.timeIntervalSinceReferenceDate * 2.5)))
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
// onAppear + firstLoad switchFlashTick) -> the Limitless title lands
// with an exaggerated flourish (several styles to audition).

struct IntroSlideIn: ViewModifier {
    @ObservedObject var model: AppModel
    let fromLeft: Bool
    @State private var on = true

    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0)
            .offset(x: on ? 0 : (fromLeft ? -70 : 70))
            .onAppear { model.accounts.isEmpty ? (on = false) : play() }
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

    func body(content: Content) -> some View {
        let dy: CGFloat = switch model.introStyle {
        case "top": -44
        case "bottom": 44
        default: 0
        }
        content
            .opacity(on ? 1 : 0)
            .offset(y: on ? 0 : dy)
            .onAppear { model.accounts.isEmpty ? (on = false) : play() }
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
            .onAppear { model.accounts.isEmpty ? (on = false) : play() }
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
    func introTitle(_ model: AppModel) -> some View {
        modifier(IntroTitleFlourish(model: model))
    }
}
