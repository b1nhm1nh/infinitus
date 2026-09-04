import SwiftUI
import InfinitusCore

/// The Mac's Stats tab on the phone: the four periods' totals from the
/// mirror snapshot (no day series — the bundle is kept small).
struct StatsScreen: View {
    @ObservedObject var model: MirrorModel
    @State private var period: Stats.Period = .week

    var body: some View {
        List {
            Picker("Period", selection: $period) {
                ForEach(Stats.Period.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            if let s = model.stats?.summary(period) {
                section("Throughput", [
                    ("Commits", n(s.total.commits), n(s.previous.commits)),
                    ("Lines +/−", "\(s.total.linesAdded) / \(s.total.linesRemoved)", nil),
                    ("PRs opened / merged", "\(s.total.prsOpened) / \(s.total.prsMerged)", nil),
                    ("Tool calls", n(s.total.totalToolCalls), n(s.previous.totalToolCalls)),
                ])
                section("Messages & sessions", [
                    ("Keyboard", n(s.total.humanMessages), n(s.previous.humanMessages)),
                    ("Phone", n(s.total.phoneMessages), n(s.previous.phoneMessages)),
                    ("Agents", n(s.total.agentMessages), n(s.previous.agentMessages)),
                    ("Sessions", n(s.total.sessionCount), n(s.previous.sessionCount)),
                ])
                section("Autonomy & friction", [
                    ("Messages per commit", f(s.total.messagesPerCommit), nil),
                    ("Tool calls per message", f(s.total.toolCallsPerHumanMessage), nil),
                    ("Waiting on you", "\(Int(s.total.waitingSeconds / 60)) min", nil),
                    ("Tool errors", n(s.total.toolErrors), n(s.previous.toolErrors)),
                ])
                section("Limits", [
                    ("Switches", n(s.total.switches), n(s.previous.switches)),
                    ("Accounts hit a limit", n(s.total.limitStops), n(s.previous.limitStops)),
                    ("Minutes lost, all out", n(Int(s.total.minutesLostToLimits)), nil),
                ])
                section("Cost (estimate)", [
                    ("Spend", "$" + String(format: "%.2f", s.total.usd), "$" + String(format: "%.2f", s.previous.usd)),
                    ("Per commit", s.total.usdPerCommit.map { "$" + String(format: "%.2f", $0) } ?? "—", nil),
                ])
                Section {
                    Text("\(s.from) – \(s.to) · streak \(s.streak) days")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            } else {
                ContentUnavailableView("No stats yet", systemImage: "chart.bar",
                                       description: Text("The Mac sends them once its first scan finishes."))
            }
        }
        .navigationTitle("Stats")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func n(_ v: Int) -> String { v.formatted() }
    private func f(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "—" }

    private func section(_ title: String, _ rows: [(String, String, String?)]) -> some View {
        Section(title) {
            ForEach(rows, id: \.0) { row in
                LabeledContent(row.0) {
                    HStack(spacing: 6) {
                        Text(row.1).monospacedDigit()
                        if let prev = row.2 {
                            Text("was \(prev)").font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                        }
                    }
                }
            }
        }
    }
}
