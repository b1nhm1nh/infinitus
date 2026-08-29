import SwiftUI
import AppKit
import CswapCore

/// The one AppKit knob that lets a popover-only accessory app live with no
/// open windows: without it, SwiftUI terminates the process as soon as the
/// last window closes (verified live — the app died the moment the keepalive
/// window was closed OR ordered out).
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Injected by CswapBarApp.init; the status item is created HERE, in
    // applicationDidFinishLaunching — creating an NSStatusItem before the
    // app finishes launching fails silently (no item, no error).
    var makeStatusItem: (() -> Void)?
    var statusHolder: StatusItemHolder?

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeStatusItem?()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        false
    }

    /// `open CswapBar.app` on an already-running instance lands here: show
    /// the pinned window. This is the guaranteed way into the UI when the
    /// menu bar is too full to display the status item at all.
    func applicationShouldHandleReopen(_ app: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        statusHolder?.controller.showPinnedWindow()
        return false
    }
}

@main
struct CswapBarApp: App {
    @StateObject private var model: AppModel
    @StateObject private var settingsModel: SettingsModel
    @StateObject private var reliabilityModel: ResumeReliabilityModel
    @StateObject private var notifyModel: NotifyModel
    @StateObject private var usageModel: UsageModel
    @StateObject private var updateModel: UpdateModel
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Menu bar app: no Dock icon, no main window.
        NSApplication.shared.setActivationPolicy(.accessory)
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        let settingsModel = SettingsModel(cli: model.cli)
        _settingsModel = StateObject(wrappedValue: settingsModel)
        let notifyModel = NotifyModel(cli: model.cli)
        _notifyModel = StateObject(wrappedValue: notifyModel)
        let usage = UsageModel(cli: model.cli)
        _usageModel = StateObject(wrappedValue: usage)
        let update = UpdateModel(cli: model.cli)
        _updateModel = StateObject(wrappedValue: update)
        update.restartEngine = { [weak model] in model?.restartEngine() }
        update.startAutoCheck()
        let reliabilityModel = ResumeReliabilityModel()
        _reliabilityModel = StateObject(wrappedValue: reliabilityModel)
        // Warm the multi-second transcript scan at launch so the Usage tab
        // and the gamified gold column open onto data, not a spinner.
        usage.loadIfNeeded()
        appDelegate.makeStatusItem = { [weak appDelegate] in
            appDelegate?.statusHolder = StatusItemHolder(
                model: model, usage: usage,
                settingsTabs: {
                    settingsTabs(
                        model: model, settingsModel: settingsModel,
                        reliabilityModel: reliabilityModel,
                        notifyModel: notifyModel, usageModel: usage,
                        updateModel: update)
                })
        }
        model.startFeeds()
        // Deferred past didFinishLaunching: requesting in App.init — before
        // the app is registered with Notification Center — fails with
        // "Notifications are not allowed for this application".
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            Notifier.requestAuthorization()
        }
        Task { await model.refreshSnapshot() }
    }

    var body: some Scene {
        // No MenuBarExtra scene: the status item is a raw NSStatusItem owned
        // by StatusItemController (see its header for why). Keep-alive with
        // zero windows comes from KeepAliveDelegate.

        Settings {
            SettingsRoot(tabs: settingsTabs(
                model: model, settingsModel: settingsModel,
                reliabilityModel: reliabilityModel,
                notifyModel: notifyModel, usageModel: usageModel,
                updateModel: updateModel))
        }
    }
}

/// The settings panes, declared once. The Settings scene (the standard
/// app-menu path, unreachable for an accessory app with no app menu)
/// renders them as a SwiftUI TabView; the controller-owned window the
/// popup's Settings… button opens renders them as an AppKit
/// NSTabViewController(tabStyle: .toolbar) — the REAL icon-toolbar
/// Settings look, which no public SwiftUI TabViewStyle reproduces.
func settingsTabs(
    model: AppModel, settingsModel: SettingsModel,
    reliabilityModel: ResumeReliabilityModel,
    notifyModel: NotifyModel, usageModel: UsageModel,
    updateModel: UpdateModel
) -> [SettingsTab] {
    [
        SettingsTab(title: "cswap", symbol: "gearshape",
                    view: AnyView(SettingsPane(model: settingsModel))),
        SettingsTab(title: "Resume reliability", symbol: "arrow.clockwise",
                    view: AnyView(ResumeReliabilityPane(model: reliabilityModel))),
        SettingsTab(title: "Display", symbol: "menubar.rectangle",
                    view: AnyView(DisplayPane(model: model))),
        SettingsTab(title: "Activity", symbol: "clock.arrow.circlepath",
                    view: AnyView(ActivityPane(model: model))),
        SettingsTab(title: "Away push", symbol: "antenna.radiowaves.left.and.right",
                    view: AnyView(NotifyPane(model: notifyModel))),
        SettingsTab(title: "Usage", symbol: "chart.bar",
                    view: AnyView(UsagePane(model: usageModel))),
        SettingsTab(title: "About", symbol: "info.circle",
                    view: AnyView(AboutPane(model: updateModel))),
    ]
}

struct SettingsRoot: View {
    let tabs: [SettingsTab]

    var body: some View {
        TabView {
            ForEach(tabs, id: \.title) { tab in
                tab.view.tabItem { Label(tab.title, systemImage: tab.symbol) }
            }
        }
        .frame(minWidth: 600, minHeight: 520)
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var usage: UsageModel
    @ObservedObject private var status = ServiceStatusModel.shared

    var body: some View {
        Group {
            if model.compactRows {
                // Compact: controls live in a left rail so the accounts sit
                // as high and tight as the bar allows.
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 10) {
                        Button { model.showSettings?() } label: {
                            Image(systemName: "gearshape")
                        }
                        .help("Settings")
                        Button { model.popoverPinned.toggle() } label: {
                            Image(systemName: model.popoverPinned ? "pin.fill" : "pin")
                        }
                        .help("Pin keeps this popup open when you click elsewhere")
                        Button { model.compactRows.toggle() } label: {
                            Image(systemName: "rectangle.expand.vertical")
                        }
                        .help("Show actions and the full footer")
                        serviceDot
                        if model.appUpdatePending {
                            Button { model.relaunchApp() } label: {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .foregroundStyle(.orange)
                            }
                            .help("A newer build is on disk — restart to update")
                        }
                        engineBadgeIcon
                        Spacer(minLength: 0)
                        Button { model.shutdown() } label: {
                            Image(systemName: "power")
                        }
                        .help("Quit")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        AccountRows(model: model, usage: usage)
                        errorLines
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    AccountRows(model: model, usage: usage)
                    Divider()
                    HStack {
                        Button("Rotate to next") { model.rotate() }
                        Button("Refresh") { Task { await model.refreshSnapshot() } }
                        Button("Test notification") {
                            Notifier.post(title: "claude-swap", body: "test — notifications reach you")
                        }
                        Spacer()
                        engineBadge
                    }
                    errorLines
                    Divider()
                    HStack {
                        Button {
                            model.showSettings?()
                        } label: {
                            Label("Settings…", systemImage: "gearshape")
                        }
                        Button {
                            model.popoverPinned.toggle()
                        } label: {
                            Label(model.popoverPinned ? "Unpin" : "Pin",
                                  systemImage: model.popoverPinned ? "pin.fill" : "pin")
                        }
                        .help("Pin keeps this popup open when you click elsewhere; "
                              + "the menu bar icon still closes it.")
                        Button {
                            model.compactRows.toggle()
                        } label: {
                            Label("Compact", systemImage: "rectangle.compress.vertical")
                        }
                        .help("Hide actions, event log, and history")
                        serviceChip
                        Spacer()
                        if model.appUpdatePending {
                            Button {
                                model.relaunchApp()
                            } label: {
                                Label("Restart to update",
                                      systemImage: "arrow.triangle.2.circlepath")
                                    .foregroundStyle(.orange)
                            }
                            .help("A newer build is on disk")
                        }
                        Button {
                            model.shutdown()   // engine stops first
                        } label: {
                            Label("Quit", systemImage: "power")
                        }
                        .help("Quit")
                    }
                }
            }
        }
        .padding(12)
        .frame(minWidth: model.compactRows ? 360 : 560)
        .dynamicTypeSize(model.popupDynamicTypeSize)
        .onAppear { status.refreshIfStale() }
    }

    @ViewBuilder private var errorLines: some View {
        if let err = model.lastError {
            Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }

    /// Claude service status — a colored dot; click opens the status page.
    private var serviceDot: some View {
        Button { status.openPage() } label: {
            Circle().fill(status.color).frame(width: 8, height: 8)
        }
        .help(status.helpText)
    }

    private var serviceChip: some View {
        Button { status.openPage() } label: {
            HStack(spacing: 4) {
                Circle().fill(status.color).frame(width: 7, height: 7)
                Text(status.shortText).font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help(status.helpText)
    }

    @ViewBuilder private var engineBadge: some View {
        switch model.engineState {
        case .running: Label("auto", systemImage: "bolt.fill").foregroundStyle(.green)
        case .refused: Label("engine elsewhere", systemImage: "exclamationmark.triangle")
            .help("Another auto-switch engine (TUI or cswap auto) holds the mutex.")
        case .backingOff(let s): Label("retry \(Int(s))s", systemImage: "clock")
        case .schemaMismatch: Label("update app", systemImage: "arrow.down.circle")
        case .stopped: Label("off", systemImage: "pause")
        }
    }

    @ViewBuilder private var engineBadgeIcon: some View {
        switch model.engineState {
        case .running: Image(systemName: "bolt.fill").foregroundStyle(.green).help("auto-switch running")
        case .refused: Image(systemName: "exclamationmark.triangle")
            .help("Another auto-switch engine (TUI or cswap auto) holds the mutex.")
        case .backingOff(let s): Image(systemName: "clock").help("engine retrying in \(Int(s))s")
        case .schemaMismatch: Image(systemName: "arrow.down.circle").help("update the app")
        case .stopped: Image(systemName: "pause").help("engine off")
        }
    }
}

/// Layout chooser: wide grid rows (the classic) or stacked per-account
/// cards (narrow popup, e.g. on an ultrawide where the bar sits far away).
struct AccountRows: View {
    @ObservedObject var model: AppModel
    @ObservedObject var usage: UsageModel

    var body: some View {
        Group {
            if model.popupLayout == "stacked" {
                AccountStack(model: model, usage: usage)
            } else {
                AccountGrid(model: model, usage: usage)
            }
        }
        // Warm the cash figures when the popup opens in a themed mode: a
        // background `cswap usage` run, cached in the shared UsageModel.
        .onAppear { if !model.rowTheme.plain { usage.loadIfNeeded() } }
    }
}

/// Shared cell builders for both layouts — one vocabulary (RowTheme),
/// one set of rendering rules (compact hides untouched/exhausted cells,
/// themed gauges show what's LEFT, plain shows used %).
@MainActor
struct AccountCells {
    let model: AppModel
    let usage: UsageModel
    let account: Account
    /// Wide grid rows paint the active band per cell; stacked cards paint
    /// one rounded background instead.
    var banded = true

    var theme: RowTheme { model.rowTheme }
    var dead: Bool { AccountVitals.isDead(account.usage) }

    /// "Max 20x" -> "20x" in compact mode; "Enterprise" -> "Ent".
    var planText: String? {
        guard let plan = account.plan else { return nil }
        guard model.compactRows else { return plan }
        return plan.replacingOccurrences(of: "Max ", with: "")
            .replacingOccurrences(of: "Enterprise", with: "Ent")
    }

    var displayName: String {
        let name = [dead ? theme.deadMarker : nil,
                    account.icon, account.alias ?? account.email]
            .compactMap { $0 }.joined(separator: " ")
        return (account.disabled ?? false) ? "\(name)  (disabled)" : name
    }

    /// Compact mode drops cells that carry no signal: untouched (0%) and
    /// exhausted (100% — the dead marker already says it).
    func hiddenInCompact(_ pct: Double) -> Bool {
        model.compactRows && (pct <= 0 || pct >= 100)
    }

    @ViewBuilder var aheadIcon: some View {
        if theme.aheadIcon.hasPrefix("sf:") {
            let symbol = String(theme.aheadIcon.dropFirst(3))
            Image(systemName: symbol)
                .symbolRenderingMode(symbol == "flame.circle.fill" ? .palette : .monochrome)
                .foregroundStyle(.white, .orange)
        } else {
            Text(theme.aheadIcon).font(.caption)
        }
    }

    func resetText(_ w: UsageWindow) -> String? {
        guard let when = model.compactRows
            ? ResetLabel.compact(w) : ResetLabel.label(w) else { return nil }
        return (w.pct >= 100 ? theme.revivePrefix : "") + when
    }

    /// Reset label that goes LIVE under ten minutes: a per-second m:ss
    /// countdown, then a pulsing "resetting…" until the next snapshot
    /// replaces the data.
    @ViewBuilder func resetLabelView(resetsAt: String?, staticText: String?) -> some View {
        if let date = WeeklyRoll.parse(resetsAt),
           date.timeIntervalSinceNow < 600 {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let left = date.timeIntervalSince(ctx.date)
                if left <= 0 {
                    Text("resetting…")
                        .font(.caption).bold().foregroundStyle(.green)
                        .opacity(0.35 + 0.65 * abs(sin(
                            ctx.date.timeIntervalSinceReferenceDate * 2.5)))
                } else {
                    Text(String(format: "%d:%02d", Int(left) / 60, Int(left) % 60))
                        .font(.caption).bold().monospacedDigit()
                        .foregroundStyle(.orange)
                        .contentTransition(.numericText(countsDown: true))
                }
            }
        } else if let staticText {
            Text(staticText).font(.caption).foregroundStyle(.secondary)
        }
    }

    var deadCause: AccountVitals.DeadCause? { AccountVitals.cause(account.usage) }

    /// One line replacing every usage cell on a dead row: the themed name
    /// of the blocking limit plus its revival time. The healthy windows
    /// carry no signal on an unusable account.
    @ViewBuilder var deadCell: some View {
        if let cause = deadCause {
            HStack(spacing: 4) {
                Text(causeLabel(cause))
                    .font(.caption).bold()
                    .foregroundStyle(ThemeColor.resolve(causeColor(cause)))
                if !theme.revivePrefix.isEmpty {
                    Text(theme.revivePrefix.trimmingCharacters(in: .whitespaces))
                        .font(.caption).foregroundStyle(.secondary)
                }
                resetLabelView(
                    resetsAt: cause.resetsAt,
                    staticText: ResetLabel.label(
                        resetsAt: cause.resetsAt, countdown: cause.countdown,
                        clock: cause.clock))
            }
            .help("Out of this limit — the account is unusable until it resets")
            .fixedSize()
            .activeBand(banded && account.active)
        }
    }

    private func causeLabel(_ cause: AccountVitals.DeadCause) -> String {
        switch cause.kind {
        case .session: return theme.sessionLabel
        case .weekly: return theme.weeklyLabel
        case .scoped: return theme.scopedPrefix + (cause.name ?? "?")
        case .credit: return theme.creditLabel
        }
    }

    private func causeColor(_ cause: AccountVitals.DeadCause) -> String {
        switch cause.kind {
        case .session: return theme.sessionColor
        case .weekly: return theme.weeklyColor
        case .scoped: return theme.scopedColor
        case .credit: return theme.creditColor
        }
    }

    @ViewBuilder func windowCell(_ w: UsageWindow?, session: Bool) -> some View {
        Group {
            if let w, !hiddenInCompact(w.pct) {
                HStack(spacing: 3) {
                    if !session {
                        // Ahead-of-pace marker — ALWAYS in the layout,
                        // invisible when pace is fine, so columns never
                        // shift (a conditional icon broke alignment).
                        aheadIcon
                            .opacity(w.aheadOfPace == true ? 1 : 0)
                            .help("Burning faster than the window elapses")
                    }
                    if theme.plain {
                        Text(session ? theme.sessionLabel : theme.weeklyLabel)
                            .foregroundStyle(.secondary)
                        Text("\(Int(w.pct))%")
                            .foregroundStyle(w.pct >= 100 ? .red : .primary)
                            .monospacedDigit()
                            .contentTransition(.numericText(value: w.pct))
                    } else {
                        Text(session ? theme.sessionLabel : theme.weeklyLabel)
                            .font(.caption).bold()
                            .foregroundStyle(ThemeColor.resolve(
                                session ? theme.sessionColor : theme.weeklyColor))
                            .help(session ? "Session window left" : "Weekly window left")
                        GaugeBar(
                            remaining: GaugeMath.remaining(usedPct: w.pct),
                            color: ThemeColor.resolve(
                                session ? theme.sessionColor : theme.weeklyColor))
                    }
                    resetLabelView(resetsAt: w.resetsAt, staticText: resetText(w))
                }
            } else if w == nil, !model.compactRows {
                Text("—").foregroundStyle(.tertiary)
            } else {
                Text(verbatim: "")
            }
        }
        // fixedSize: usage is the row's payload — grow the popup rather
        // than truncate. The name column is the one flexible column.
        .fixedSize()
        .activeBand(banded && account.active)
    }

    @ViewBuilder var spendCell: some View {
        if let spend = account.usage?.spend, !hiddenInCompact(spend.pct) {
            HStack(spacing: 3) {
                Text(theme.creditLabel)
                    .font(theme.plain ? .body : .caption.bold())
                    .foregroundStyle(theme.plain
                                     ? Color.secondary
                                     : ThemeColor.resolve(theme.creditColor))
                if theme.plain {
                    Text("\(Int(spend.pct))%")
                        .foregroundStyle(spend.pct >= 100 ? .red : .primary)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: spend.pct))
                } else {
                    GaugeBar(remaining: GaugeMath.remaining(usedPct: spend.pct),
                             color: ThemeColor.resolve(theme.creditColor))
                }
            }
            .help(String(format: "usage credit: %.2f of %.0f %@",
                         spend.used, spend.limit, spend.currency))
            .fixedSize()
            .activeBand(banded && account.active)
        } else {
            // Text, not Color.clear: a zero-size cell renders the active
            // band as a stray blob; an empty Text has line height.
            Text(verbatim: "")
                .activeBand(banded && account.active)
        }
    }

    @ViewBuilder var scopedCells: some View {
        ForEach(account.usage?.scoped ?? [], id: \.name) { w in
            Group {
                if hiddenInCompact(w.pct) {
                    Text(verbatim: "")
                } else {
                    HStack(spacing: 3) {
                        aheadIcon
                            .opacity(w.aheadOfPace == true ? 1 : 0)
                            .help("Burning faster than the window elapses")
                        if theme.plain {
                            Text(w.name ?? "?").foregroundStyle(.secondary)
                            Text("\(Int(w.pct))%")
                                .foregroundStyle(w.pct >= 100 ? .red : .primary)
                                .monospacedDigit()
                                .contentTransition(.numericText(value: w.pct))
                        } else {
                            Text(theme.scopedPrefix + (w.name ?? "?"))
                                .font(.caption).bold()
                                .foregroundStyle(ThemeColor.resolve(theme.scopedColor))
                                .help("Model weekly limit left")
                            GaugeBar(remaining: GaugeMath.remaining(usedPct: w.pct),
                                     color: ThemeColor.resolve(theme.scopedColor))
                        }
                    }
                }
            }
            .fixedSize()
            .activeBand(banded && account.active)
        }
    }

    /// Estimated 7-day API-price spend from the Usage tab's cached
    /// report — never triggers the multi-second scan itself.
    @ViewBuilder var cashCell: some View {
        if !theme.plain,
           let row = usage.report?.accounts.first(where: { $0.number == account.number }) {
            let usd = Int(row.estimatedUSD)
            Text(verbatim: model.compactRows && usd >= 1000
                 ? "\(theme.cashIcon)\(Int((Double(usd) / 1000).rounded()))k"
                 : "\(theme.cashIcon)\(usd.formatted())")
                .font(.caption).foregroundStyle(.yellow)
                .help("Estimated API-price spend, last \(usage.report?.days ?? 7) days — not a bill")
                .fixedSize()
                .activeBand(banded && account.active)
        }
    }
}

/// Maps a theme color string — named or "#rrggbb" — to a SwiftUI Color.
enum ThemeColor {
    static func resolve(_ name: String) -> Color {
        switch name {
        case "red": return .red
        case "blue": return .blue
        case "green": return .green
        case "yellow": return .yellow
        case "orange": return .orange
        case "purple": return .purple
        case "indigo": return .indigo
        case "cyan": return .cyan
        case "teal": return .teal
        case "pink": return .pink
        case "mint": return .mint
        case "gray", "secondary": return .secondary
        default:
            guard name.hasPrefix("#"), name.count == 7,
                  let v = UInt32(name.dropFirst(), radix: 16) else { return .primary }
            return Color(red: Double((v >> 16) & 0xff) / 255,
                         green: Double((v >> 8) & 0xff) / 255,
                         blue: Double(v & 0xff) / 255)
        }
    }
}

/// The account rows as a real Grid — the alignment the rumps menubar had to
/// fake with monospaced padding (spec §4). The active row gets a contiguous
/// highlight band: Grid offers no per-row background, so each cell paints one
/// and extends it exactly half the row's spacing in every direction — the
/// segments meet edge-to-edge (an overlap would double the translucent
/// color's alpha and show as darker stripes).
struct AccountGrid: View {
    @ObservedObject var model: AppModel
    @ObservedObject var usage: UsageModel

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            ForEach(model.accounts, id: \.number) { account in
                let cells = AccountCells(model: model, usage: usage, account: account)
                GridRow {
                    HStack(spacing: 2) {
                        // Advisory: who the auto-switcher would pick next.
                        // Always in the layout so numbers stay aligned.
                        Image(systemName: "arrowtriangle.right.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                            .opacity(model.nextCandidate == account.number ? 1 : 0)
                            .help("Next auto-switch target")
                        Text("\(account.number)")
                            .fontWeight(account.active ? .bold : .regular)
                            .foregroundStyle(account.active ? Color.accentColor : Color.primary)
                    }
                    .activeBand(account.active)
                    Button(cells.displayName) {
                        model.switchTo(account.number)   // disabled rows stay clickable, like rumps
                    }
                    .buttonStyle(.plain)
                    .fontWeight(account.active ? .bold : .regular)
                    .foregroundStyle((account.disabled ?? false) || cells.dead
                                     ? AnyShapeStyle(.secondary)
                                     : account.active
                                     ? AnyShapeStyle(Color.accentColor)
                                     : AnyShapeStyle(.primary))
                    .help(cells.dead ? "Out of at least one limit — unusable until it resets"
                                     : "Switch to this account")
                    .lineLimit(1)
                    // The one deliberately flexible column: emails truncate,
                    // usage numbers and reset times never do.
                    .frame(minWidth: 110, maxWidth: 230, alignment: .leading)
                    .activeBand(account.active)
                    Text(cells.planText ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .activeBand(account.active)
                    if let note = SentinelNotes.note(for: account.usageStatus) {
                        Text(note)
                            .foregroundStyle(.secondary)
                            .gridCellColumns(3)   // spans the usage columns
                            .activeBand(account.active)
                    } else if cells.dead {
                        // A dead row shows ONLY what blocks it — a full MP
                        // gauge on an unusable account reads as usable.
                        cells.deadCell
                            .gridCellColumns(3)
                        cells.cashCell
                    } else {
                        cells.windowCell(account.usage?.fiveHour, session: true)
                        cells.windowCell(account.usage?.sevenDay, session: false)
                        cells.spendCell
                        cells.scopedCells
                        cells.cashCell
                    }
                }
            }
        }
    }
}

/// Stacked layout: one card per account — narrow and tall instead of wide.
struct AccountStack: View {
    @ObservedObject var model: AppModel
    @ObservedObject var usage: UsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.accounts, id: \.number) { account in
                let cells = AccountCells(model: model, usage: usage, account: account, banded: false)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrowtriangle.right.fill")
                            .font(.caption2).foregroundStyle(.green)
                            .opacity(model.nextCandidate == account.number ? 1 : 0)
                            .help("Next auto-switch target")
                        Text("\(account.number)")
                            .fontWeight(.bold)
                            .foregroundStyle(account.active ? Color.accentColor : Color.secondary)
                        Button(cells.displayName) { model.switchTo(account.number) }
                            .buttonStyle(.plain)
                            .fontWeight(account.active ? .bold : .regular)
                            .foregroundStyle((account.disabled ?? false) || cells.dead
                                             ? .secondary : .primary)
                            .lineLimit(1)
                        if let plan = cells.planText {
                            Text(plan).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        cells.cashCell
                    }
                    if let note = SentinelNotes.note(for: account.usageStatus) {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    } else if cells.dead {
                        cells.deadCell
                    } else {
                        HStack(spacing: 12) {
                            cells.windowCell(account.usage?.fiveHour, session: true)
                            cells.windowCell(account.usage?.sevenDay, session: false)
                        }
                        HStack(spacing: 12) {
                            cells.spendCell
                            cells.scopedCells
                        }
                    }
                }
                .padding(6)
                .background {
                    if account.active {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor.opacity(0.26))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.accentColor.opacity(0.7)))
                    }
                }
            }
        }
    }
}

private struct ActiveBand: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content.background {
            if active {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.30))
                    .padding(.vertical, -4)     // half the Grid's verticalSpacing
                    .padding(.horizontal, -6)   // half the horizontalSpacing
            }
        }
    }
}

private extension View {
    func activeBand(_ on: Bool) -> some View { modifier(ActiveBand(active: on)) }
}

/// Type-erased LabelStyle so one Label can flip icon-only <-> titled at
/// runtime (the ternary needs a single concrete type).
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init(_ style: some LabelStyle) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }
    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}
