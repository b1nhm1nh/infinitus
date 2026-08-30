import SwiftUI

/// Number of segment ticks retired 2026-08-30: the bar is now a CodexBar-
/// style continuous capsule (ported from steipete/CodexBar
/// UsageProgressBar.swift, adapted to themes): a single Canvas draws the
/// track, the remaining-fill, and a punch-out pace stripe — a transparent
/// gap through the bar with a colored center stripe at the position the
/// pace says you SHOULD be. Green stripe = reserve, red = deficit.
/// Canvas + context blend modes on purpose (CodexBar issue #805: SwiftUI
/// .blendMode/.compositingGroup trigger shader compilation on macOS 26).
struct GaugeBar: View {
    let remaining: Double
    let color: Color
    /// Remaining % the pace expects (100 - expectedPct); nil = no stripe.
    var paceRemaining: Double? = nil
    @ScaledMetric(relativeTo: .caption) private var barWidth = 52.0
    @ScaledMetric(relativeTo: .caption) private var barHeight = 6.0

    var body: some View {
        HStack(spacing: 3) {
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                let radius = size.height / 2
                let corner = CGSize(width: radius, height: radius)
                let clamped = min(100, max(0, remaining))

                context.clip(to: Path(roundedRect: rect, cornerSize: corner))

                // Track
                context.fill(Path(roundedRect: rect, cornerSize: corner),
                             with: .color(Color.secondary.opacity(0.22)))
                // Fill (remaining, left-anchored)
                let fillWidth = size.width * clamped / 100
                if fillWidth > 0.5 {
                    let fillRect = CGRect(x: 0, y: 0, width: fillWidth,
                                          height: size.height)
                    context.fill(Path(roundedRect: fillRect, cornerSize: corner),
                                 with: .color(color))
                }

                // Pace stripe: punch a slanted gap through track+fill, then
                // draw the slimmer colored stripe in its center.
                if let pace = paceRemaining {
                    let clampedPace = min(100, max(0, pace))
                    let x = size.width * clampedPace / 100
                    let slant = size.height * 0.35
                    let punchW: CGFloat = 5
                    let stripeW: CGFloat = 1.8

                    func slantedPath(center: CGFloat, width: CGFloat) -> Path {
                        Path { p in
                            p.move(to: CGPoint(x: center - width / 2 + slant, y: -2))
                            p.addLine(to: CGPoint(x: center + width / 2 + slant, y: -2))
                            p.addLine(to: CGPoint(x: center + width / 2 - slant,
                                                  y: size.height + 2))
                            p.addLine(to: CGPoint(x: center - width / 2 - slant,
                                                  y: size.height + 2))
                            p.closeSubpath()
                        }
                    }

                    context.blendMode = .destinationOut
                    context.fill(slantedPath(center: x, width: punchW),
                                 with: .color(.white.opacity(0.9)))
                    context.blendMode = .normal
                    let deficit = clamped < clampedPace
                    context.fill(slantedPath(center: x, width: stripeW),
                                 with: .color(deficit ? .red : .green))
                }
            }
            .frame(width: barWidth, height: barHeight)

            Text("\(Int(remaining))%")
                .font(.caption).monospacedDigit()
                .foregroundStyle(remaining <= 0 ? Color.red : color.opacity(0.9))
        }
    }
}
