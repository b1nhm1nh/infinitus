// Sources/Infinitus/StatsPane.swift
import SwiftUI
import Charts
import InfinitusCore

/// Settings › Stats: engineering metrics per period (user 2026-09-04).
/// Tiles = value, delta vs the previous period, sparkline of the days —
/// the tile catalogue itself lives in `Stats.Presentation` (fix round 1)
/// so the phone renders the exact same list; this file keeps only what's
/// Mac-specific (picker, scanning line, sparklines, heatmap, session
/// length chart, footnotes, Refresh).
struct StatsPane: View {
    @ObservedObject var model: StatsModel
    @AppStorage("stats_period") private var periodRaw = Stats.Period.week.rawValue

    private var period: Stats.Period { Stats.Period(rawValue: periodRaw) ?? .week }
    private var summary: Stats.Summary? { model.summaries[period] }

    var body: some View {
        Form {
            Section {
                Picker("Period", selection: $periodRaw) {
                    ForEach(Stats.Period.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                if let s = summary {
                    Text("\(s.from) – \(s.to) · streak \(s.streak) day\(s.streak == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                if model.scanning {
                    HStack { ProgressView().controlSize(.small); Text(model.progress ?? "Scanning…") }
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let s = summary {
                ForEach(Stats.Presentation.groups(s)) { group($0) }
                Section("Rhythm") {
                    heatmap(s.total.hours)
                    sessionLengths(s)
                }
            }
            Section {
                ForEach(model.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                Button("Refresh") { model.refresh() }.disabled(model.scanning)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.loadIfNeeded() }
    }

    // MARK: tiles

    private func group(_ g: Stats.Presentation.Group) -> some View {
        Section(g.id) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(g.tiles) { tileView($0) }
            }
            .padding(.vertical, 4)
        }
    }

    private func tileView(_ t: Stats.Presentation.Tile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t.id).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(t.value).font(.title3.weight(.semibold)).monospacedDigit()
                if let delta = t.delta {
                    Text(delta).font(.caption2).foregroundStyle(delta.hasPrefix("+") ? .green : delta.hasPrefix("−") ? .orange : .secondary)
                }
            }
            if t.series.contains(where: { $0 != 0 }) {
                Chart(Array(t.series.enumerated()), id: \.offset) { i, v in
                    AreaMark(x: .value("d", i), y: .value("v", v)).foregroundStyle(Color.accentColor.opacity(0.18))
                    LineMark(x: .value("d", i), y: .value("v", v)).foregroundStyle(Color.accentColor)
                }
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .frame(height: 26)
            } else {
                Spacer(minLength: 26)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.controlBackgroundColor)))
    }

    // MARK: rhythm

    private func heatmap(_ raw: [Int]) -> some View {
        // `model.summaries` is never compacted (that's the exporter's
        // form, which empties `hours`) — but index math on a 168-slot
        // array is not worth a trap if that ever changes.
        let hours = raw.count == 168 ? raw : Array(repeating: 0, count: 168)
        let peak = max(1, hours.max() ?? 1)
        let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        return VStack(alignment: .leading, spacing: 3) {
            Text("Activity by hour").font(.caption).foregroundStyle(.secondary)
            ForEach(0..<7, id: \.self) { d in
                HStack(spacing: 2) {
                    Text(days[d]).font(.caption2).monospacedDigit().frame(width: 28, alignment: .leading)
                    ForEach(0..<24, id: \.self) { h in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor.opacity(0.08 + 0.92 * Double(hours[d * 24 + h]) / Double(peak)))
                            .frame(height: 12)
                            .help("\(days[d]) \(h):00 — \(hours[d * 24 + h]) entries")
                    }
                }
            }
            HStack(spacing: 2) {
                Spacer().frame(width: 28)
                ForEach([0, 6, 12, 18], id: \.self) { h in
                    Text("\(h):00").font(.caption2).foregroundStyle(.tertiary)
                    if h != 18 { Spacer() }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func sessionLengths(_ s: Stats.Summary) -> some View {
        let rows = Stats.Presentation.sessionLengthRows(s)
        return VStack(alignment: .leading, spacing: 3) {
            Text("Session lengths").font(.caption).foregroundStyle(.secondary)
            Chart(rows, id: \.label) { row in
                BarMark(x: .value("Sessions", row.count), y: .value("Bucket", row.label))
                    .foregroundStyle(Color.accentColor)
            }
            .chartXAxis(.hidden)
            .frame(height: 90)
            HStack {
                Spacer()
                Text(Stats.Presentation.sessionTimeLine(s))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 4)
    }
}
