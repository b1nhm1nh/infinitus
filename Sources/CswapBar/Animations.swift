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

/// The data-changed ripple: a small dot that blooms a ring outward every
/// time `trigger` bumps — quiet proof the numbers on screen just moved.
struct DataPulseDot: View {
    let trigger: Int

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 6, height: 6)
            .background {
                Circle()
                    .stroke(Color.accentColor, lineWidth: 1.5)
                    .keyframeAnimator(initialValue: RingState(),
                                      trigger: trigger) { view, state in
                        view.scaleEffect(state.scale)
                            .opacity(state.opacity)
                    } keyframes: { _ in
                        KeyframeTrack(\.scale) {
                            CubicKeyframe(1.0, duration: 0.001)
                            CubicKeyframe(3.2, duration: 0.8)
                        }
                        KeyframeTrack(\.opacity) {
                            CubicKeyframe(0.9, duration: 0.001)
                            CubicKeyframe(0.0, duration: 0.8)
                        }
                    }
            }
            .help("Blinks when the popup's data changes")
    }

    struct RingState {
        var scale = 1.0
        var opacity = 0.0
    }
}

extension View {
    func switchFlash(_ trigger: Int) -> some View {
        modifier(SwitchFlash(trigger: trigger))
    }
}
