import SwiftUI
import InfinitusCore
import InfinitusUI

/// The Fleet tab (#9 native shell): a real inset-grouped `List` of the
/// mirrored accounts. The SHELL is iOS — navigation stack, large title,
/// pull-to-refresh, row taps into a sheet, context menu, haptics — while
/// every gauge, marker, label and effect inside a row is the shared
/// vocabulary (`AccountHeaderLine` / `AccountUsageLines` over
/// `AccountCells`), in the Mac's own order.
struct NativeFleetScreen: View {
    @ObservedObject var model: MirrorModel
    @ObservedObject var usage: MobileUsage
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var detail: AccountRef?
    /// Row width, for the wide (landscape / regular) row order. Measured
    /// from a background probe rather than a GeometryReader WRAPPER — a
    /// wrapper between the navigation stack and the list breaks the
    /// large title (it collapsed to an inline one, first run).
    @State private var width: CGFloat = 0

    /// `.sheet(item:)` needs identity and `Account` is a plain Codable —
    /// the number is the fleet's identity everywhere else too.
    private struct AccountRef: Identifiable { let id: Int }

    var body: some View {
        NavigationStack {
            content(wide: width > 600 || sizeClass == .regular)
                .navigationTitle("Fleet")
                .refreshable { await model.refresh() }
                .background {
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { measure(geo.size) }
                            .onChange(of: geo.size) { _, size in measure(size) }
                    }
                }
                .onAppear { usage.loadIfNeeded() }
        }
        // The one shared cue that has a phone equivalent: a switch is a
        // success beat, an account dying is a warning one. The trigger is
        // the ACTIVE ACCOUNT, not switchFlashTick — the tick also bumps on
        // every intro replay (i.e. every foregrounding), which would buzz
        // the phone for nothing.
        .sensoryFeedback(.success, trigger: model.activeNumber)
        .sensoryFeedback(.warning, trigger: deathCount)
        .sheet(item: $detail) { ref in
            if let account = model.accounts.first(where: { $0.number == ref.id }) {
                AccountDetailSheet(model: model, usage: usage, account: account)
            }
        }
        // The bars take their fill-up cue from the environment, not the
        // model (GaugeBar has no model) — same wiring as the Mac popup.
        .environment(\.introTick, model.introTick)
        .environment(\.introBarDelay, model.introBarDelay)
    }

    @ViewBuilder private func content(wide: Bool) -> some View {
        if model.accounts.isEmpty {
            ContentUnavailableView {
                Label("Waiting for the fleet", systemImage: "antenna.radiowaves.left.and.right")
            } description: {
                Text(model.error ?? "No snapshot yet. The Mac app exports "
                     + "one automatically — check Settings › Mac connection "
                     + "if this stays empty.")
            }
        } else {
            List {
                allDeadSection
                accountSection(wide: wide)
            }
            .listStyle(.insetGrouped)
        }
    }

    /// The large title's subtitle line — `.navigationSubtitle` is macOS
    /// only, so the machine/as-of caption (and the staleness capsule)
    /// ride the accounts section's header.
    @ViewBuilder private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let snapshot = model.snapshot {
                // Fresh: machine + as-of on one caption. Stale: the
                // capsule below carries the as-of, so the caption drops
                // it rather than printing the same time twice.
                Text(isStale(snapshot.capturedAt)
                     ? snapshot.machineName
                     : "\(snapshot.machineName) · as of "
                       + snapshot.capturedAt.formatted(date: .omitted, time: .shortened))
                    .font(.subheadline).foregroundStyle(.secondary)
                if isStale(snapshot.capturedAt) {
                    Label("as of \(snapshot.capturedAt.formatted(date: .omitted, time: .shortened)) — is the Mac awake?",
                          systemImage: "clock.badge.exclamationmark")
                        .font(.caption).foregroundStyle(.orange)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.yellow.opacity(0.18), in: Capsule())
                }
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .textCase(nil)
        .padding(.bottom, 2)
    }

    /// Every account at a limit: the shared banner (recovering account +
    /// live countdown) in a card of its own, themed tint.
    @ViewBuilder private var allDeadSection: some View {
        if model.nextCandidate == nil, model.nextRecovery != nil {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "heart.slash.fill")
                        .font(.title3).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fleet is out").font(.headline)
                        AllDeadBanner(model: model)
                    }
                }
                .padding(.vertical, 4)
                .listRowBackground(ThemeColor.flash(model.rowTheme).opacity(0.18))
            }
        }
    }

    private func accountSection(wide: Bool) -> some View {
        Section {
            ForEach(Array(model.displayAccounts.enumerated()),
                    id: \.element.number) { index, account in
                row(account, index: index, wide: wide)
            }
        } header: {
            statusHeader
        }
    }

    private func row(_ account: Account, index: Int, wide: Bool) -> some View {
        // A Button, not an onTapGesture: inside a List that's the tap
        // target that actually fires (and gets the press highlight for
        // free) — a gesture on the row content never did.
        Button {
            detail = AccountRef(id: account.number)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                AccountHeaderLine(model: model, usage: usage, account: account)
                AccountUsageLines(model: model, usage: usage,
                                  account: account, wide: wide)
                    // The gauges carry no tap of their own on a phone;
                    // the whole row is the target.
                    .allowsHitTesting(false)
            }
            .padding(.vertical, 6)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Paused accounts read dimmed; the ⏸ marker is in the name.
            .opacity((account.disabled ?? false) ? 0.55 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                UIPasteboard.general.string = account.email
            } label: {
                Label("Copy email", systemImage: "doc.on.doc")
            }
        }
        .listRowBackground(rowBackground(account))
        // The Mac's dying alarm, over the row's own bounds.
        .overlay {
            if AccountRowVitals.isCritical(account) { CriticalPulse() }
        }
        // Same effect chain, same order as the Mac's stacked cards.
        .switchFlash(account.active ? model.switchFlashTick : 0,
                     color: ThemeColor.flash(model.rowTheme))
        .deathFlash(model.deathTicks[account.number] ?? 0)
        .reviveFlash(model.reviveTicks[account.number] ?? 0)
        .introRow(model, index: index)
    }

    /// The Mac's active band, as a native row fill: the theme's flash
    /// tint (the app accent when the theme sets none).
    @ViewBuilder private func rowBackground(_ account: Account) -> some View {
        ZStack {
            // The list's own row fill, explicitly: a listRowBackground
            // replaces it, so without this the rows read as holes in the
            // grouped card (first run, light mode).
            Color(.secondarySystemGroupedBackground)
            if AccountRowVitals.isLucky(account, theme: model.rowTheme) {
                LuckyRowBackground(cornerRadius: 0)
            }
            if account.active {
                ThemeColor.flash(model.rowTheme).opacity(0.22)
            }
        }
    }

    private func measure(_ size: CGSize) {
        width = size.width
        // The Mac-popup view reads the same orientation cue.
        model.isLandscape = size.width > size.height
    }

    private var deathCount: Int {
        model.deathTicks.values.reduce(0, +)
    }

    private func isStale(_ capturedAt: Date) -> Bool {
        Date().timeIntervalSince(capturedAt) > 180
    }
}

/// A row tap opens the whole account: every window in full (labels,
/// gauges, percentages, absolute reset times), plus the plan and the
/// cash estimate. Read-only by design — the phone drives no engine.
private struct AccountDetailSheet: View {
    @ObservedObject var model: MirrorModel
    @ObservedObject var usage: MobileUsage
    let account: Account
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Slot", value: "#\(account.number)")
                    LabeledContent("Email", value: account.email)
                    if let plan = account.plan {
                        LabeledContent("Plan", value: plan)
                    }
                    LabeledContent("State", value: stateText)
                } header: {
                    Text("Account")
                }
                Section("Windows") {
                    AccountWindowDetails(model: model, account: account)
                }
                if let report = usage.report,
                   let row = report.accounts.first(where: { $0.number == account.number }) {
                    Section("Estimated spend") {
                        LabeledContent("Last \(report.days) days",
                                       value: "$\(Int(row.estimatedUSD).formatted())")
                        Text("An API-price estimate, never a bill.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(account.alias ?? account.email)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var stateText: String {
        if account.active { return "active" }
        if account.disabled ?? false { return "disabled" }
        if AccountRowVitals.isDead(account) { return "at a limit" }
        if model.nextCandidate == account.number { return "next up" }
        return "standby"
    }
}
