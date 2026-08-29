import SwiftUI
import CswapCore

/// The statusline's slim 8-cell RPG gauge, in SwiftUI: filled cells in the
/// stat color, empty cells dim, the percentage riding alongside. Shows
/// REMAINING (HP/MP semantics) — a fresh account is a full bar.
struct GaugeBar: View {
    let remaining: Double
    let color: Color
    // Scaled so the popup-size setting (dynamic type) grows the gauges
    // along with the text.
    @ScaledMetric(relativeTo: .caption) private var cellWidth = 5.0
    @ScaledMetric(relativeTo: .caption) private var cellHeight = 9.0

    var body: some View {
        let filled = GaugeMath.filled(remaining)
        HStack(spacing: 1) {
            ForEach(0..<GaugeMath.cells, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < filled ? color : Color.secondary.opacity(0.25))
                    .frame(width: cellWidth, height: cellHeight)
            }
            Text("\(Int(remaining))%")
                .font(.caption).monospacedDigit()
                .foregroundStyle(remaining <= 0 ? .red : .secondary)
                .padding(.leading, 2)
        }
    }
}
