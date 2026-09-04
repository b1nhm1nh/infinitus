import SwiftUI
import InfinitusCore

/// The Mac's Stats tab on the phone: the same tile catalogue
/// (`Stats.Presentation`, fix round 1) as `StatsPane`, minus the
/// sparklines and the hour heatmap — everything else the Mac shows,
/// same names, same values, same deltas.
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
                ForEach(Stats.Presentation.groups(s)) { group in
                    Section(group.id) {
                        ForEach(group.tiles) { tile in
                            LabeledContent(tile.id) {
                                HStack(spacing: 6) {
                                    Text(tile.value).monospacedDigit()
                                    if let delta = tile.delta {
                                        Text(delta).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                                    }
                                }
                            }
                        }
                    }
                }
                Section("Rhythm") {
                    ForEach(Stats.Presentation.sessionLengthRows(s), id: \.label) { row in
                        LabeledContent(row.label, value: n(row.count))
                    }
                    Text(Stats.Presentation.sessionTimeLine(s))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
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
}
