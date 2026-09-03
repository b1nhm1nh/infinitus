import SwiftUI
import Charts
import InfinitusCore

/// Utilization-over-time dashboard (todo 2026-09-01): charts the recorded
/// 5h/7d/per-model percentages for the whole fleet or one account, plus
/// waste — the headroom that expired unused at each weekly reset. Reads
/// the merged local + iCloud history; loading is file IO, so it runs
/// off-main on demand like the spend scan above it.
@MainActor
final class UtilizationModel: ObservableObject {
    @Published var samples: [UsageSample] = []
    @Published var generations: [WindowGeneration] = []
    @Published var fiveHourWindows: [FiveHourWindow] = []
    /// #7 layer 2: what the fleet did over the range, and the plan the
    /// planner would propose off the latest samples if a sprint were
    /// running — a dry run for eyeballing, nothing executes.
    @Published var replay: WindowPlanner.ReplayReport?
    @Published var dryRunPlan: WindowPlanner.Plan?
    @Published var loading = false
    @Published var rangeDays = 7 { didSet { if rangeDays != oldValue { refresh() } } }
    /// "7d", "5h", or a scoped model name.
    @Published var window = "7d"
    /// nil = every account overlaid.
    @Published var account: String?

    /// Window choices actually present in the data, stable order.
    var windows: [String] {
        var names: [String] = ["5h", "7d"]
        var seen = Set<String>()
        for s in samples {
            for name in (s.scoped ?? [:]).keys where seen.insert(name).inserted {
                names.append(name)
            }
        }
        return names
    }

    var emails: [String] {
        var seen = Set<String>()
        return samples.compactMap { seen.insert($0.email).inserted ? $0.email : nil }
    }

    func loadIfNeeded() { if samples.isEmpty && !loading { refresh() } }

    func refresh() {
        guard !loading else { return }
        loading = true
        let days = rangeDays
        Task.detached(priority: .utility) {
            let urls = UsageHistoryRecorder.readableURLs()
            let merged = UsageHistory.merge(urls.map { UsageHistory.load(url: $0) })
            // Waste generations and 5h windows need the FULL history (a
            // reset may predate the chart range); the chart gets the
            // trimmed, thinned slice.
            let gens = WasteMath.generations(merged)
            let windows = WindowTelemetry.fiveHourWindows(
                merged, now: Date().timeIntervalSince1970)
            let now = Date().timeIntervalSince1970
            let cutoff = now - Double(days) * 86400
            let bucket: TimeInterval = days <= 1 ? 300 : days <= 7 ? 1800 : 7200
            let thin = UsageHistory.downsample(
                merged.filter { $0.t >= cutoff }, bucket: bucket)
            let replay = WindowPlanner.replay(merged, from: cutoff, to: now)
            let plan = Self.dryRunPlan(merged, now: now)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.samples = thin
                self.generations = gens
                self.fiveHourWindows = windows
                self.replay = replay
                self.dryRunPlan = plan
                self.loading = false
            }
        }
    }
}

extension UtilizationModel {
    /// The planner over each account's latest sample (within the last
    /// hour, so a stale file doesn't fake a fleet), assuming one busy
    /// session. Disabled accounts aren't in the history; the live card
    /// (next layer) gets the real snapshot.
    nonisolated static func dryRunPlan(_ samples: [UsageSample], now: Double) -> WindowPlanner.Plan? {
        var latest: [String: UsageSample] = [:]
        for s in samples where s.t >= now - 3600 {
            if let cur = latest[s.email], cur.t >= s.t { continue }
            latest[s.email] = s
        }
        let states = latest.values.map { s in
            let weekly = ([s.sevenDay?.pct] + (s.scoped ?? [:]).values.map { $0.pct })
                .compactMap { $0 }.max() ?? 0
            return WindowPlanner.AccountState(
                number: s.number, email: s.email, active: s.active == true,
                fiveHourPct: s.fiveHour?.pct, fiveHourResetsAt: s.fiveHour?.resetsAt,
                weeklyPct: weekly)
        }
        guard let active = states.first(where: { $0.active }) else { return nil }
        let rate = WindowTelemetry.burnRate(samples, email: active.email, now: now)
        return WindowPlanner.plan(accounts: states, burnPctPerHour: rate,
                                  busySessions: 1, now: now)
    }
}

struct UtilizationPane: View {
    @ObservedObject var model: UtilizationModel

    var body: some View {
        Form {
            HStack {
                Picker("Range", selection: $model.rangeDays) {
                    Text("24 hours").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                }
                .frame(maxWidth: 200)
                Spacer()
                if model.loading {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Refresh") { model.refresh() }
                }
            }
            if model.samples.isEmpty && !model.loading {
                Text("No history yet — samples accrue while Infinitus runs "
                     + "(one per engine usage poll).")
                    .foregroundStyle(.secondary)
            } else {
                utilizationSection
                fiveHourSection
                battlePlanSection
                wasteSection
            }
        }
        .formStyle(.grouped)
        .onAppear { model.loadIfNeeded() }
    }

    // MARK: utilization over time

    private struct Point: Identifiable {
        let id: String
        let date: Date
        let series: String
        let pct: Double
    }

    @ViewBuilder private var utilizationSection: some View {
        Section {
            Picker("Account", selection: $model.account) {
                Text("All accounts").tag(String?.none)
                ForEach(model.emails, id: \.self) { e in
                    Text(shortName(e)).tag(String?.some(e))
                }
            }
            if model.account == nil {
                Picker("Window", selection: $model.window) {
                    ForEach(model.windows, id: \.self) { Text($0) }
                }
                .pickerStyle(.segmented)
            }
            Chart(chartPoints()) { p in
                LineMark(x: .value("Time", p.date), y: .value("%", p.pct))
                    .foregroundStyle(by: .value("Series", p.series))
                    .interpolationMethod(.monotone)
                    // Dots as well as lines: a series with one sample
                    // (fresh install, sparse hours) draws no line at all.
                    .symbol(by: .value("Series", p.series))
                    .symbolSize(18)
            }
            .chartYScale(domain: 0...100)
            .chartLegend(.visible)
            .frame(height: 190)
            .padding(.vertical, 4)
        } header: {
            Text(model.account.map { "Windows — \(shortName($0))" }
                 ?? "Utilization — \(model.window)")
        } footer: {
            Text("One point per engine usage poll, thinned for the range. "
                 + "Gaps are hours this Mac (or its engine) wasn't running.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// All-accounts mode: one series per account on the picked window.
    /// Single-account mode: one series per window for that account.
    private func chartPoints() -> [Point] {
        var out: [Point] = []
        for s in model.samples {
            if let email = model.account {
                guard s.email == email else { continue }
                let date = Date(timeIntervalSince1970: s.t)
                if let w = s.fiveHour {
                    out.append(Point(id: "5h|\(s.t)", date: date,
                                     series: "5h", pct: w.pct))
                }
                if let w = s.sevenDay {
                    out.append(Point(id: "7d|\(s.t)", date: date,
                                     series: "7d", pct: w.pct))
                }
                for (name, w) in s.scoped ?? [:] {
                    out.append(Point(id: "\(name)|\(s.t)", date: date,
                                     series: name, pct: w.pct))
                }
            } else {
                let w: UsageSample.Window? = switch model.window {
                case "5h": s.fiveHour
                case "7d": s.sevenDay
                default: s.scoped?[model.window]
                }
                guard let w else { continue }
                out.append(Point(id: "\(s.email)|\(s.t)",
                                 date: Date(timeIntervalSince1970: s.t),
                                 series: shortName(s.email), pct: w.pct))
            }
        }
        return out
    }

    // MARK: 5h windows

    private struct RhythmBar: Identifiable {
        let id: Int
        var hour: Int { id }
        let count: Int
    }

    /// Reconstructed windows for the selected account, or every account
    /// overlaid — newest first, so `.prefix(10)` is "the last 10".
    private func selectedWindows() -> [FiveHourWindow] {
        let windows = model.account.map { email in
            model.fiveHourWindows.filter { $0.email == email }
        } ?? model.fiveHourWindows
        return windows.sorted { $0.start > $1.start }
    }

    @ViewBuilder private var fiveHourSection: some View {
        let windows = selectedWindows()
        if !windows.isEmpty {
            Section {
                ForEach(Array(windows.prefix(10))) { w in
                    HStack {
                        if model.account == nil {
                            Text(shortName(w.email))
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .leading)
                        }
                        Text(clockLabel(w.start)).monospacedDigit()
                        Spacer()
                        Text(String(format: "%.0f%% peak", w.peakPct))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        if w.closed && w.peakPct < 5 {
                            Text("unused")
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.orange.opacity(0.2), in: Capsule())
                                .foregroundStyle(.orange)
                        } else if !w.closed {
                            Text("open")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                let s = WindowTelemetry.summary(windows)
                Text("\(s.count) window\(s.count == 1 ? "" : "s")"
                     + " · mean peak " + String(format: "%.0f%%", s.meanPeak)
                     + " · \(s.unusedWindows) unused")
                    .font(.caption).foregroundStyle(.secondary)
                Chart(rhythmBars(windows)) { b in
                    BarMark(x: .value("Hour", b.hour), y: .value("Windows", b.count))
                }
                .frame(height: 80)
                .padding(.vertical, 4)
            } header: {
                Text(model.account.map { "5h windows — \(shortName($0))" }
                     ?? "5h windows")
            } footer: {
                Text("Peak % observed inside each reconstructed 5h window "
                     + "(windows are use-it-or-lose-it, so peak is what "
                     + "\"used\" means). Bars: how many windows have "
                     + "started at each hour of day — the sprint rhythm.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: battle plan (#7 layer 2, dry run)

    @ViewBuilder private var battlePlanSection: some View {
        if let r = model.replay {
            Section {
                if r.sawActiveFlag {
                    Text("\(r.switches) switch\(r.switches == 1 ? "" : "es")"
                         + " · \(r.coldSwitches) onto a cold clock"
                         + " · stalled " + durationLabel(r.stalledSeconds))
                        .monospacedDigit()
                } else {
                    Text("No switch data in this range yet — samples carry the "
                         + "active account from this version on.")
                        .foregroundStyle(.secondary)
                }
                if let plan = model.dryRunPlan {
                    ForEach(plan.steps) { step in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(clockLabel(step.at)).monospacedDigit()
                                Text(actionLabel(step.action)).bold()
                                Spacer()
                            }
                            Text(step.why).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("Nothing to plan right now: no bind projected within "
                         + "two hours of the active account's window.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Battle plan — dry run")
            } footer: {
                Text("Replay of the range above: how often the fleet switched, "
                     + "how many switches landed on an account with no 5h window "
                     + "ticking (a plan would have ignited it first), and how long "
                     + "the active account sat at 100%. Below it, the plan the "
                     + "planner would propose from the latest samples if a sprint "
                     + "were running. Nothing here runs anything.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func actionLabel(_ a: WindowPlanner.Action) -> String {
        switch a {
        case .ignite(let n): return "ignite #\(n)"
        case .switchTo(let n): return "switch to #\(n)"
        case .hold(let n): return "hold #\(n)"
        case .reset(let n): return "#\(n) resets"
        }
    }

    private func durationLabel(_ s: Double) -> String {
        let m = Int((s / 60).rounded())
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }

    private func rhythmBars(_ windows: [FiveHourWindow]) -> [RhythmBar] {
        let hist = WindowTelemetry.dailyRhythm(windows)
        return (0..<24).map { RhythmBar(id: $0, count: hist[$0] ?? 0) }
    }

    private func clockLabel(_ t: Double) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    // MARK: waste

    @ViewBuilder private var wasteSection: some View {
        let rows = wasteRows()
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(shortName(row.email)).lineLimit(1)
                            Spacer()
                            Text(String(format: "%.0f%% wasted avg", row.avgWaste))
                                .monospacedDigit()
                                .foregroundStyle(row.avgWaste >= 50 ? .orange : .secondary)
                        }
                        Text("\(row.count) weekly reset\(row.count == 1 ? "" : "s")"
                             + " observed · worst "
                             + String(format: "%.0f%%", row.worstWaste)
                             + (row.window == "7d" ? "" : " · \(row.window)"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Waste at weekly resets")
            } footer: {
                Text("Waste = headroom still unused when a 7-day window "
                     + "rolled over — quota that expired. An estimate from "
                     + "the last sample before each reset, never billing "
                     + "truth; sparse sampling overstates it.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private struct WasteRow: Identifiable {
        let id: String
        let email: String
        let window: String
        let avgWaste: Double
        let worstWaste: Double
        let count: Int
    }

    /// Per account+window aggregate over the closed generations, largest
    /// average waste first. Only generations whose last observation was
    /// within a day of the reset count — beyond that the "final" pct is
    /// a guess about a window we barely watched.
    private func wasteRows() -> [WasteRow] {
        var groups: [String: [WindowGeneration]] = [:]
        for g in model.generations where g.observationGap < 86400 {
            groups["\(g.email)|\(g.window)", default: []].append(g)
        }
        return groups.map { key, gens in
            let sep = key.firstIndex(of: "|")!
            return WasteRow(
                id: key,
                email: String(key[..<sep]),
                window: String(key[key.index(after: sep)...]),
                avgWaste: gens.map(\.wastePct).reduce(0, +) / Double(gens.count),
                worstWaste: gens.map(\.wastePct).max() ?? 0,
                count: gens.count)
        }
        .sorted { $0.avgWaste > $1.avgWaste }
    }

    private func shortName(_ email: String) -> String {
        String(email.prefix(while: { $0 != "@" }))
    }
}
