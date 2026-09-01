import SwiftUI
import CswapCore

/// One usage window as a labeled capsule gauge — label, bar, remaining %,
/// reset. Small and reusable so account rows don't grow one giant body
/// (this repo's ViewBuilder type-check-stall history).
struct GaugeRowView: View {
    let label: String
    let window: UsageWindow

    private var remaining: Double { GaugeMath.remaining(usedPct: window.pct) }

    private var color: Color {
        remaining <= 10 ? .red : remaining <= 25 ? .orange : .mint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(remaining))%")
                    .font(.caption).monospacedDigit().foregroundStyle(color)
                if let reset = ResetLabel.label(resetsAt: window.resetsAt,
                                               countdown: window.countdown,
                                               clock: window.clock) {
                    Text(reset)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(color.gradient)
                        .frame(width: max(4, geo.size.width * remaining / 100))
                }
            }
            .frame(height: 8)
        }
    }
}
