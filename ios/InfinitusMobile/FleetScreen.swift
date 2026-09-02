import SwiftUI
import CswapCore
import InfinitusUI

struct FleetScreen: View {
    @ObservedObject var model: MirrorModel
    @StateObject private var usage = MobileUsage()
    @Environment(\.scenePhase) private var scenePhase
    @State private var settingsShown = false

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ScrollView {
                    // The popup's own padding (AppModel-driven, like the
                    // mac's MenuContent) — no List: grouped insets and
                    // separators can't match the popover.
                    VStack(alignment: .leading, spacing: 10) {
                        if let error = model.error {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                        if model.snapshot == nil, model.error == nil {
                            // First launch, no mirror yet — say so instead of a
                            // blank list (flagged in the phase-2 report).
                            ContentUnavailableView(
                                "Waiting for the fleet",
                                systemImage: "antenna.radiowaves.left.and.right",
                                description: Text("No snapshot yet. The Mac app "
                                    + "exports one automatically; in the simulator, "
                                    + "launch with INFINITUS_MIRROR_PATH pointing at "
                                    + "its mirror-snapshot.json."))
                        }
                        if let snapshot = model.snapshot, isStale(snapshot.capturedAt) {
                            StalenessBanner(capturedAt: snapshot.capturedAt)
                        }
                        // Placeholders until #9 phase B2 lands the shared
                        // header / all-dead hero / sessions card — each is
                        // then a one-line swap for the InfinitusUI view.
                        if model.nextCandidate == nil, let rec = model.nextRecovery {
                            DeadHero(recovery: rec, accounts: model.accounts)
                        }
                        accountArea
                        if let sessions = model.snapshot?.sessions, !sessions.isEmpty {
                            Text("Sessions").font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(sessions.enumerated()), id: \.offset) { _, row in
                                SessionRow(row: row)
                            }
                        }
                    }
                    .padding(model.compactRows ? 8 : 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear { model.isLandscape = geo.size.width > geo.size.height }
                .onChange(of: geo.size) { _, size in
                    withAnimation(.easeInOut(duration: 0.3)) {
                        model.isLandscape = size.width > size.height
                    }
                }
            }
            .navigationTitle(model.snapshot?.machineName ?? "Infinitus")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button { settingsShown = true } label: { Image(systemName: "gearshape") }
            }
            .refreshable { await model.refresh() }
            .task {
                while !Task.isCancelled {
                    await model.refresh()
                    try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
                }
            }
            .sheet(isPresented: $settingsShown) { SettingsScreen(model: model) }
        }
        // ONE tip chip for the whole screen, drawn above every row —
        // same plumbing the mac popup uses.
        .overlayPreferenceValue(ActiveTipKey.self) { InstantTipCanvas(tips: $0) }
        // The bars take their fill-up cue from the environment, not the
        // model (GaugeBar has no model) — set it once, like MenuContent.
        .environment(\.introTick, model.introTick)
        .environment(\.introBarDelay, model.introBarDelay)
        // The popup replays its intro when it opens; the phone's
        // equivalent is coming back to the foreground. First launch is
        // the first snapshot's replay, so it isn't doubled here.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, model.snapshotLoaded { model.replayIntro() }
        }
    }

    /// The shared popup rows — cards in portrait, the wide grid in
    /// landscape (MirrorModel.popupLayout). The grid measures itself at
    /// the mac's point width, so landscape gets a horizontal scroller
    /// for the fleets that overflow the phone; the cards stretch to the
    /// screen and must NOT be fixedSize'd (they'd go ragged).
    @ViewBuilder private var accountArea: some View {
        Group {
            if model.accounts.isEmpty {
                EmptyView()
            } else if model.popupLayout == "wide" {
                ScrollView(.horizontal, showsIndicators: false) {
                    AccountRows(model: model, usage: usage).fixedSize()
                }
            } else {
                AccountRows(model: model, usage: usage)
            }
        }
        .introContent(model)
    }

    private func isStale(_ capturedAt: Date) -> Bool {
        Date().timeIntervalSince(capturedAt) > 180
    }
}

private struct StalenessBanner: View {
    let capturedAt: Date

    var body: some View {
        Text("as of \(capturedAt.formatted(date: .omitted, time: .shortened)) — is the Mac awake?")
            .font(.caption).foregroundStyle(.orange)
    }
}

private struct DeadHero: View {
    let recovery: NextRecovery
    let accounts: [Account]

    private var reviverName: String {
        guard let a = accounts.first(where: { $0.number == recovery.number }) else {
            return "#\(recovery.number)"
        }
        return a.alias ?? String(a.email.prefix(while: { $0 != "@" }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(reviverName) recovers in")
                .font(.subheadline).foregroundStyle(.secondary)
            if let until = UsageHistory.parseISO(recovery.at) {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(RecoveryCountdown.label(until: until, now: ctx.date))
                        .font(.system(size: 44, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.orange)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

/// One session's compact progress line — status dot, repo, then the
/// mobile priority chain (retrying > nowDoing > todos), quiet-minutes
/// suffix, goal as a dimmed second line.
private struct SessionRow: View {
    let row: SessionPanelRow

    private var dotColor: Color {
        switch row.status {
        case "busy": return .orange
        case "waiting": return .yellow
        default: return .gray
        }
    }

    private var progressText: String? {
        if row.retrying { return "retrying" }
        if let nowDoing = row.nowDoing { return nowDoing }
        if let total = row.todosTotal {
            let counts = "\(row.todosDone ?? 0)/\(total)"
            guard let activeForm = row.activeForm else { return counts }
            return "\(counts) · \(activeForm)"
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Text(row.repo).font(.body.weight(.semibold)).lineLimit(1)
                if let text = progressText {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(row.retrying ? .orange : .secondary)
                        .lineLimit(1)
                }
                if let quiet = row.quietMinutes {
                    Spacer(minLength: 0)
                    Text("quiet \(quiet)m")
                        .font(.caption2).foregroundStyle(.gray)
                }
            }
            if let goal = row.goal {
                Text(goal)
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
