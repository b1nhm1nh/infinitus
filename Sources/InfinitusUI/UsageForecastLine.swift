import SwiftUI
import InfinitusCore

/// The prediction line (2026-09-03): at the measured pace, when each
/// window of the active account hits its limit and when the fleet is
/// out. Clock times, never a ticking countdown (a per-second text tick
/// is what the heap-growth gate exists for). Gauge names come from the
/// row theme so the RPG face reads "MP"/"HP", not "5h"/"7d". Hidden
/// when nothing is projected. The tooltip carries the pace and basis.
public struct UsageForecastLine<M: FleetModel>: View {
    @ObservedObject var model: M

    public init(model: M) {
        self.model = model
    }

    @ViewBuilder public var body: some View {
        if let f = model.forecast, let text = summary(f) {
            (Text(Image(systemName: "hourglass"))
                .foregroundStyle(.orange)
             + Text(" " + text))
                .font(PopupFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .help(help(f))
        }
    }

    /// Public so the pane and the phone can render the same words.
    public static func clauses(_ f: UsageForecast, theme: RowTheme, now: Date = Date()) -> [String] {
        var out: [String] = []
        for w in f.active?.windows ?? [] {
            guard let at = w.hitsAt else { continue }
            let label = w.name == "5h" ? theme.sessionLabel
                : w.name == "7d" ? theme.weeklyLabel : w.name
            out.append("\(label) out \(ForecastClock.label(at, now: now))")
        }
        if let dead = f.allDeadAt {
            out.append("all accounts out \(ForecastClock.label(dead, now: now))")
        }
        return out
    }

    private func summary(_ f: UsageForecast) -> String? {
        let clauses = Self.clauses(f, theme: model.rowTheme)
        guard !clauses.isEmpty else { return nil }
        return "At this pace: " + clauses.joined(separator: " · ")
    }

    private func help(_ f: UsageForecast) -> String {
        let paces = (f.active?.windows ?? []).map { w -> String in
            let rate = w.ratePctPerHour.map { String(format: "%.1f%%/h", $0) } ?? "pace unknown"
            let fate = w.hitsAt == nil && w.ratePctPerHour != nil ? " — resets before it fills" : ""
            return "\(w.name): \(Int(w.pct.rounded()))% at \(rate)\(fate)"
        }
        return (paces + ["Estimate. " + f.basis]).joined(separator: "\n")
    }
}

/// "now", "~4:12 PM" today, "~Fri 9:00 AM" inside a week, else a date.
public enum ForecastClock {
    public static func label(_ epoch: Double, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: epoch)
        if date.timeIntervalSince(now) <= 30 { return "now" }
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        if Calendar.current.isDate(date, inSameDayAs: now) {
            f.dateStyle = .none
            f.timeStyle = .short
        } else if date.timeIntervalSince(now) < 6 * 86_400 {
            f.setLocalizedDateFormatFromTemplate("EEE jmm")
        } else {
            f.setLocalizedDateFormatFromTemplate("MMM d jmm")
        }
        return "~" + f.string(from: date)
    }
}
