// Sources/Infinitus/StatsPane.swift
import SwiftUI
import Charts
import InfinitusCore

/// Settings › Stats: engineering metrics per period (user 2026-09-04).
/// Tiles = value, delta vs the previous period, sparkline of the days.
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
                group("Throughput", [
                    tile("Commits", s, \.commits),
                    tile("Lines +", s, \.linesAdded),
                    tile("Lines −", s, \.linesRemoved),
                    tile("PRs opened", s, \.prsOpened),
                    tile("PRs merged", s, \.prsMerged),
                    tile("Turns", s, \.turns),
                    tile("Tool calls", s, \.totalToolCalls),
                    tile("Output tokens", s, \.outputTokens),
                ])
                group("Messages & sessions", [
                    tile("Keyboard", s, \.humanMessages),
                    tile("Phone", s, \.phoneMessages),
                    tile("Agents", s, \.agentMessages),
                    tile("Nudges", s, \.nudges),
                    tile("Sessions", s, \.sessionCount),
                    tile("Sub-agents", s, \.subagents),
                ])
                group("Autonomy", [
                    ratio("Messages / commit", s, \.messagesPerCommit),
                    ratio("Tool calls / message", s, \.toolCallsPerHumanMessage),
                    tile("Longest unattended", s, \.longestUnattended, unit: "tool calls"),
                    percent("Human share", s, \.humanShare),
                ])
                group("Friction", [
                    minutes("Waiting on you", s, \.waitingSeconds),
                    tile("Questions", s, \.questions),
                    tile("Denied tools", s, \.denials),
                    tile("Tool errors", s, \.toolErrors),
                    tile("API retries", s, \.retries),
                    tile("Compactions", s, \.compactions),
                ])
                group("Limits", [
                    tile("Switches", s, \.switches),
                    tile("Accounts hit a limit", s, \.limitStops),
                    tile("Revivals", s, \.revivals),
                    tile("Minutes lost, all out", s, \.minutesLostToLimits, format: { Int($0).formatted() }),
                    tile("Ignites", s, \.ignites),
                    tile("Resumes", s, \.resumes),
                ])
                group("Cost (API-equivalent estimate)", [
                    money("Spend", s, \.usd),
                    money("Per commit", s, \.usdPerCommit),
                    money("Per PR", s, \.usdPerPR),
                    ratio("Tokens / line", s, \.tokensPerLine),
                    ratio("Mean hours to merge", s, \.meanMergeHours),
                ])
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

    private struct Tile: Identifiable {
        let id: String
        let value: String
        let delta: String?
        let series: [Double]
    }

    private func group(_ title: String, _ tiles: [Tile]) -> some View {
        Section(title) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(tiles) { tileView($0) }
            }
            .padding(.vertical, 4)
        }
    }

    private func tileView(_ t: Tile) -> some View {
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

    private func tile(_ name: String, _ s: Stats.Summary, _ key: KeyPath<Stats.Day, Int>, unit: String? = nil) -> Tile {
        let v = s.total[keyPath: key], p = s.previous[keyPath: key]
        return Tile(id: name, value: v.formatted() + (unit.map { " \($0)" } ?? ""),
                    delta: deltaText(Double(v), Double(p)),
                    series: s.daily.map { Double($0.day[keyPath: key]) })
    }

    private func tile(_ name: String, _ s: Stats.Summary, _ key: KeyPath<Stats.Day, Double>,
                      format: @escaping (Double) -> String) -> Tile {
        let v = s.total[keyPath: key], p = s.previous[keyPath: key]
        return Tile(id: name, value: format(v), delta: deltaText(v, p), series: s.daily.map { $0.day[keyPath: key] })
    }

    private func ratio(_ name: String, _ s: Stats.Summary, _ key: KeyPath<Stats.Day, Double?>) -> Tile {
        Tile(id: name, value: s.total[keyPath: key].map { String(format: "%.1f", $0) } ?? "—",
             delta: zip2(s.total[keyPath: key], s.previous[keyPath: key]).map { deltaText($0, $1) } ?? nil,
             series: s.daily.map { $0.day[keyPath: key] ?? 0 })
    }

    private func percent(_ name: String, _ s: Stats.Summary, _ key: KeyPath<Stats.Day, Double?>) -> Tile {
        Tile(id: name, value: s.total[keyPath: key].map { "\(Int($0 * 100))%" } ?? "—", delta: nil,
             series: s.daily.map { ($0.day[keyPath: key] ?? 0) * 100 })
    }

    private func minutes(_ name: String, _ s: Stats.Summary, _ key: KeyPath<Stats.Day, Double>) -> Tile {
        tile(name, s, key) { secs in
            let m = Int(secs / 60)
            return m >= 120 ? "\(m / 60) h \(m % 60) m" : "\(m) min"
        }
    }

    private func money(_ name: String, _ s: Stats.Summary, _ key: KeyPath<Stats.Day, Double>) -> Tile {
        tile(name, s, key) { "$" + String(format: $0 >= 100 ? "%.0f" : "%.2f", $0) }
    }

    private func money(_ name: String, _ s: Stats.Summary, _ key: KeyPath<Stats.Day, Double?>) -> Tile {
        Tile(id: name, value: s.total[keyPath: key].map { "$" + String(format: "%.2f", $0) } ?? "—", delta: nil,
             series: s.daily.map { $0.day[keyPath: key] ?? 0 })
    }

    private func deltaText(_ v: Double, _ p: Double) -> String? {
        guard p != 0 else { return v == 0 ? nil : "new" }
        let pct = Int(((v - p) / p * 100).rounded())
        return pct == 0 ? "±0%" : pct > 0 ? "+\(pct)%" : "−\(-pct)%"
    }

    private func zip2<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
        guard let a, let b else { return nil }
        return (a, b)
    }

    // MARK: rhythm

    private func heatmap(_ hours: [Int]) -> some View {
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
        let labels = ["< 15 min", "15–60 min", "1–4 h", "> 4 h"]
        let buckets = s.total.sessionBuckets
        let total = s.total.sessionSeconds
        let n = max(1, s.total.sessionCount)
        return VStack(alignment: .leading, spacing: 3) {
            Text("Session lengths").font(.caption).foregroundStyle(.secondary)
            Chart(Array(labels.enumerated()), id: \.offset) { i, label in
                BarMark(x: .value("Sessions", buckets[i]), y: .value("Bucket", label))
                    .foregroundStyle(Color.accentColor)
            }
            .chartXAxis(.hidden)
            .frame(height: 90)
            HStack {
                Spacer()
                Text("\(Int(total / 3600)) h total · \(Int(total / Double(n) / 60)) min per session")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 4)
    }
}
