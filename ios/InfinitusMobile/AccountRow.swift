import SwiftUI
import CswapCore

/// One account's row in the fleet list: marker, name, plan, then a gauge
/// per live window (or the dead-cause line once a window maxes out).
struct AccountRow: View {
    let account: Account
    let nextCandidate: Int?

    private var marker: String {
        if account.active { return "👑" }
        if account.number == nextCandidate { return "▶" }
        if AccountVitals.isDead(account.usage) { return "💀" }
        return "·"
    }

    private var name: String {
        account.alias ?? String(account.email.prefix(while: { $0 != "@" }))
    }

    /// Dead on the 5h window alone (weekly + per-model still viable) still
    /// surfaces the 7d/scoped gauges — the mac popover's "5h-only death"
    /// convention (`InfinitusApp.swift` AccountCells). Checked against the
    /// windows directly rather than `AccountVitals.cause`'s kind, which
    /// names whichever dead window resets LATEST and isn't reliable when
    /// more than one window is dead.
    private var deadOnFiveHourOnly: Bool {
        guard let usage = account.usage, let five = usage.fiveHour, five.pct >= 100 else { return false }
        if let seven = usage.sevenDay, seven.pct >= 100 { return false }
        if (usage.scoped ?? []).contains(where: { $0.pct >= 100 }) { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(marker)
                Text(name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                if let plan = account.plan {
                    Text(plan)
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
            }
            windows
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var windows: some View {
        if AccountVitals.isDead(account.usage) && !deadOnFiveHourOnly {
            deadLine
        } else {
            if deadOnFiveHourOnly {
                deadLine
            } else if let five = account.usage?.fiveHour {
                GaugeRowView(label: "5h", window: five)
            }
            if let seven = account.usage?.sevenDay {
                GaugeRowView(label: "7d", window: seven)
            }
            ForEach(account.usage?.scoped ?? [], id: \.name) { window in
                GaugeRowView(label: window.name ?? "model", window: window)
            }
        }
    }

    @ViewBuilder private var deadLine: some View {
        if let cause = AccountVitals.cause(account.usage) {
            HStack(spacing: 4) {
                Text("\(causeLabel(cause)) out")
                    .font(.caption).bold().foregroundStyle(.red)
                if let reset = ResetLabel.compact(resetsAt: cause.resetsAt, countdown: cause.countdown) {
                    Text(reset).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func causeLabel(_ cause: AccountVitals.DeadCause) -> String {
        switch cause.kind {
        case .session: return "5h"
        case .weekly: return "7d"
        case .scoped: return cause.name ?? "model"
        case .credit: return "spend"
        }
    }
}
