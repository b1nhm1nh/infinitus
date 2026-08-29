import SwiftUI

/// The account-switch celebration: a bright sweep that runs across the row
/// plus a brief accent glow. Attach to the active row; fires whenever
/// `trigger` changes (AppModel bumps it on every observed switch).
struct SwitchFlash: ViewModifier {
    let trigger: Int

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geo in
                    // keyframeAnimator restarts cleanly on every trigger
                    // bump — phaseAnimator would keep cycling forever.
                    let width = geo.size.width
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [.clear,
                                         Color.accentColor.opacity(0.0),
                                         Color.white.opacity(0.35),
                                         Color.accentColor.opacity(0.0),
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
                view.shadow(color: Color.accentColor.opacity(glow),
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
    @State private var tick = 0

    func body(content: Content) -> some View {
        content
            .onChange(of: value) { tick += 1 }
            .keyframeAnimator(initialValue: 0.0, trigger: tick) { view, glow in
                view
                    .shadow(color: Color.accentColor.opacity(glow), radius: 6 * glow)
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
    func switchFlash(_ trigger: Int) -> some View {
        modifier(SwitchFlash(trigger: trigger))
    }

    /// Glow in place whenever `value` changes.
    func glowOnChange<V: Equatable>(of value: V) -> some View {
        modifier(ValueChangedGlow(value: value))
    }
}
