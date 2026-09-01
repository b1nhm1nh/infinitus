import SwiftUI
import Charts
import CswapCore

// The wall's own layout (issue #12) — not the scaled popup. Read at
// 2–4 m: hero zone for the active account (or the revival countdown
// when everything is dead), a rail for sessions/status/events/history,
// a bench of the other accounts along the bottom.

struct WallLayout: View {
    @ObservedObject var model: AppModel
    @ObservedObject var status = ServiceStatusModel.shared
    @State private var sparkSamples: [UsageSample] = []

    var body: some View {
        VStack(spacing: 30) {
            HStack(alignment: .top, spacing: 44) {
                hero.frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .topLeading)
                rail.frame(width: 430, alignment: .topLeading)
            }
            bench
        }
        .padding(52)
        .onAppear(perform: loadSparks)
        // Staged switch: same confirm contract as the popup.
        .alert("Switch account?",
               isPresented: Binding(get: { model.pendingSwitch != nil },
                                    set: { if !$0 { model.pendingSwitch = nil } })) {
            Button("Switch") {
                if let n = model.pendingSwitch { model.switchTo(n) }
                model.pendingSwitch = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every Claude Code session rides the active account. "
                 + "Switch to account \(model.pendingSwitch.map(String.init) ?? "?")?")
        }
    }

    private var theme: RowTheme { model.rowTheme }
    private var allDead: Bool {
        model.nextCandidate == nil && model.nextRecovery != nil
    }
    private var active: Account? { model.accounts.first { $0.active } }

    // MARK: hero

    @ViewBuilder private var hero: some View {
        if allDead, let rec = model.nextRecovery {
            deadHero(rec)
        } else if let a = active {
            accountHero(a)
        } else {
            Text("no active account")
                .font(.system(size: 40)).foregroundStyle(.secondary)
        }
    }

    private func accountHero(_ a: Account) -> some View {
        VStack(alignment: .leading, spacing: 34) {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                Text(theme.activeIcon.isEmpty ? "●" : theme.activeIcon)
                    .font(.system(size: 46))
                Text(a.alias ?? String(a.email.prefix(while: { $0 != "@" })))
                    .font(.system(size: 62, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                if let plan = a.plan {
                    Text(theme.planLabel(plan, compact: false))
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .background(Capsule().fill(.white.opacity(0.08)))
                }
            }
            VStack(alignment: .leading, spacing: 26) {
                if let w = a.usage?.fiveHour {
                    heroGauge(label: theme.sessionLabel,
                              color: ThemeColor.resolve(theme.sessionColor),
                              w: w)
                }
                if let w = a.usage?.sevenDay {
                    heroGauge(label: theme.weeklyLabel,
                              color: ThemeColor.resolve(theme.weeklyColor),
                              w: w)
                }
                ForEach((a.usage?.scoped ?? []), id: \.name) { w in
                    heroGauge(label: theme.scopedPrefix + theme.modelName(w.name),
                              color: ThemeColor.resolve(theme.scopedColor),
                              w: w)
                }
            }
        }
    }

    private func heroGauge(label: String, color: Color, w: UsageWindow) -> some View {
        let remaining = GaugeMath.remaining(usedPct: w.pct)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(color)
                Spacer()
                Text("\(Int(remaining))%")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(remaining <= 10 ? .red : .primary)
                    .contentTransition(.numericText(value: remaining))
                if let text = ResetLabel.label(resetsAt: w.resetsAt,
                                               countdown: w.countdown,
                                               clock: w.clock) {
                    Text(text)
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 210, alignment: .trailing)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule().fill(color.gradient)
                        .frame(width: max(12, geo.size.width * remaining / 100))
                        .animation(.easeInOut(duration: 0.6), value: remaining)
                }
            }
            .frame(height: 24)
        }
    }

    private func deadHero(_ rec: NextRecovery) -> some View {
        let reviver = model.accounts.first { $0.number == rec.number }
        let name = reviver.map { $0.alias ?? String($0.email.prefix(while: { $0 != "@" })) }
            ?? "#\(rec.number)"
        return VStack(alignment: .leading, spacing: 26) {
            Label("ALL ACCOUNTS LIMITED", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 36, weight: .heavy))
                .foregroundStyle(.red)
            Text("\(name) recovers in")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            if let until = UsageHistory.parseISO(rec.at) {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(RecoveryCountdown.label(until: until, now: ctx.date))
                        .font(.system(size: 120, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.orange)
                        .contentTransition(.numericText(countsDown: true))
                }
            }
            if let waiting = model.waitingResume, waiting > 0 {
                Text("\(waiting) session\(waiting == 1 ? "" : "s") waiting to resume")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 30) {
            if let s = model.liveSessions {
                HStack(spacing: 12) {
                    Image(systemName: "brain")
                        .font(.system(size: 30))
                        .foregroundStyle(.orange)
                    Text("\(s.busy) working · \(s.total) sessions")
                        .font(.system(size: 27, weight: .semibold))
                }
            }
            HStack(spacing: 22) {
                Label(status.shortText, systemImage: "circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(status.indicator == "none" ? .green : .orange)
                Label("auto", systemImage: "bolt.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(model.engineState.isRunning ? .green : .secondary)
            }
            if !model.eventLog.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.eventLog.suffix(3).reversed()) { e in
                        Label(e.text, systemImage: e.icon)
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            if !sparkSamples.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("last 24h — binding window")
                        .font(.system(size: 17))
                        .foregroundStyle(.tertiary)
                    Chart(sparkPoints()) { p in
                        LineMark(x: .value("t", p.date), y: .value("%", p.pct))
                            .foregroundStyle(by: .value("a", p.series))
                            .interpolationMethod(.monotone)
                    }
                    .chartYScale(domain: 0...100)
                    .chartXAxis(.hidden)
                    .chartLegend(.hidden)
                    .frame(height: 190)
                }
            }
            Spacer()
        }
    }

    // MARK: bench

    private var bench: some View {
        HStack(spacing: 18) {
            ForEach(model.displayAccounts.filter { !$0.active },
                    id: \.number) { a in
                benchCard(a)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func benchCard(_ a: Account) -> some View {
        let dead = AccountVitals.isDead(a.usage)
        let worst = PushTriggers.worstPlanPct(a.usage) ?? 0
        let critical = !dead && worst >= 90
        let isNext = a.number == model.nextCandidate
        return Button {
            model.pendingSwitch = a.number
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    if isNext {
                        Text(theme.nextIcon.isEmpty ? "▶" : theme.nextIcon)
                            .font(.system(size: 18))
                    }
                    if a.disabled ?? false {
                        Image(systemName: "pause.fill").font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                    Text(a.alias ?? String(a.email.prefix(while: { $0 != "@" })))
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(dead ? .secondary : .primary)
                        .lineLimit(1)
                }
                if dead, let cause = AccountVitals.cause(a.usage) {
                    HStack(spacing: 6) {
                        Text(theme.deadMarker).font(.system(size: 18))
                        if let t = ResetLabel.compact(resetsAt: cause.resetsAt,
                                                      countdown: cause.countdown) {
                            Text(t).font(.system(size: 18))
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.08))
                        Capsule()
                            .fill(critical ? Color.red : Color.accentColor)
                            .frame(width: max(6, 170 * (100 - worst) / 100))
                    }
                    .frame(width: 170, height: 10)
                    Text("\(Int(100 - worst))% left")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(width: 226, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.white.opacity(isNext ? 0.10 : 0.05)))
            .overlay {
                if critical {
                    TimelineView(.animation(minimumInterval: 1.0 / 15)) { ctx in
                        let t = ctx.date.timeIntervalSinceReferenceDate
                        let p = sin(t * .pi / 0.8) * sin(t * .pi / 0.8)
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Color.red.opacity(0.2 + 0.5 * p),
                                          lineWidth: 2)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: sparkline data

    private func loadSparks() {
        Task.detached(priority: .utility) {
            let cutoff = Date().addingTimeInterval(-86400).timeIntervalSince1970
            let merged = UsageHistory.merge(
                UsageHistoryRecorder.readableURLs().map { UsageHistory.load(url: $0) })
            let thin = UsageHistory.downsample(
                merged.filter { $0.t >= cutoff }, bucket: 900)
            await MainActor.run { sparkSamples = thin }
        }
    }

    private struct SparkPoint: Identifiable {
        let id: String
        let date: Date
        let series: String
        let pct: Double
    }

    private func sparkPoints() -> [SparkPoint] {
        sparkSamples.compactMap { s in
            var pcts: [Double] = []
            if let p = s.fiveHour?.pct { pcts.append(p) }
            if let p = s.sevenDay?.pct { pcts.append(p) }
            for (_, w) in s.scoped ?? [:] { pcts.append(w.pct) }
            guard let worst = pcts.max() else { return nil }
            return SparkPoint(id: s.dedupeKey,
                              date: Date(timeIntervalSince1970: s.t),
                              series: String(s.email.prefix(while: { $0 != "@" })),
                              pct: worst)
        }
    }
}
