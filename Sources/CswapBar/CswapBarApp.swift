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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AccountGrid(model: model, usage: usage)
            // Compact mode hides the MIDDLE of the popup (actions, event
            // log, history) — never the reset times: those are account
            // data, the middle is chrome. Errors always show.
            if !model.compactRows {
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
            }
            if let err = model.lastError {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
            if !model.compactRows {
                if !model.eventLog.isEmpty {
                    Divider()
                    ForEach(model.eventLog.suffix(3), id: \.self) { line in
                        Text(line).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                SwitchHistoryView()
            }
            Divider()
            HStack {
                Button {
                    model.showSettings?()
                } label: {
                    Label("Settings…", systemImage: "gearshape")
                        .labelStyle(bottomRowStyle)
                }
                .help("Settings")
                Button {
                    model.popoverPinned.toggle()
                } label: {
                    Label(model.popoverPinned ? "Unpin" : "Pin",
                          systemImage: model.popoverPinned ? "pin.fill" : "pin")
                        .labelStyle(bottomRowStyle)
                }
                .help("Pin keeps this popup open when you click elsewhere; "
                      + "the menu bar icon still closes it.")
                Button {
                    model.compactRows.toggle()
                } label: {
                    Label(model.compactRows ? "Expand" : "Compact",
                          systemImage: model.compactRows
                              ? "rectangle.expand.vertical"
                              : "rectangle.compress.vertical")
                        .labelStyle(bottomRowStyle)
                }
                .help(model.compactRows ? "Show actions, event log, and history"
                                        : "Hide actions, event log, and history")
                Spacer()
                if model.compactRows {
                    // The badge's home row is hidden in compact mode; the
                    // engine state is too important to vanish with it.
                    engineBadge
                    Spacer()
                }
                Button {
                    model.shutdown()   // engine stops first
                } label: {
                    Label("Quit", systemImage: "power")
                        .labelStyle(bottomRowStyle)
                }
                .help("Quit")
            }
        }
        .padding(12)
        .frame(minWidth: 560)
    }

    /// Compact popup: icon-only bottom buttons; full popup keeps labels.
    private var bottomRowStyle: AnyLabelStyle {
        model.compactRows ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon)
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
            // (gold warms lazily below — the scan is multi-second)
            ForEach(model.accounts, id: \.number) { account in
                GridRow {
                    Text("\(account.number)")
                        .fontWeight(account.active ? .bold : .regular)
                        .foregroundStyle(account.active ? Color.accentColor : Color.primary)
                        .activeBand(account.active)
                    let disabled = account.disabled ?? false
                    let name = [account.icon, account.alias ?? account.email]
                        .compactMap { $0 }.joined(separator: " ")
                    Button(disabled ? "\(name)  (disabled)" : name) {
                        model.switchTo(account.number)   // disabled rows stay clickable, like rumps
                    }
                    .buttonStyle(.plain)
                    .fontWeight(account.active ? .bold : .regular)
                    .foregroundStyle(disabled ? .secondary : .primary)
                    .lineLimit(1)
                    // The one deliberately flexible column: emails truncate,
                    // usage numbers and reset times never do. minWidth keeps
                    // the name from collapsing to zero when gauge cells want
                    // more width than the popup has.
                    .frame(minWidth: 110, maxWidth: 230, alignment: .leading)
                    .activeBand(account.active)
                    Text(account.plan ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .activeBand(account.active)
                    if let note = SentinelNotes.note(for: account.usageStatus) {
                        Text(note)
                            .foregroundStyle(.secondary)
                            .gridCellColumns(3)   // spans the usage columns
                            .activeBand(account.active)
                    } else {
                        windowCell(account.usage?.fiveHour, label: "5h", active: account.active)
                        windowCell(account.usage?.sevenDay, label: "7d", active: account.active)
                        scopedCells(account)
                        goldCell(account)
                    }
                }
            }
        }
        // Warm the gold figures when the popup opens in gamified mode: a
        // background `cswap usage` run, cached in the shared UsageModel —
        // rows fill in when it lands, instantly on later opens.
        .onAppear { if model.gamifiedRows { usage.loadIfNeeded() } }
    }

    @ViewBuilder private func windowCell(
        _ w: UsageWindow?, label: String, active: Bool
    ) -> some View {
        Group {
            if let w {
                HStack(spacing: 3) {
                    if label != "5h" {
                        // Token-burn flame: usage is meaningfully ahead of the
                        // window's elapsed time (the feed's pace verdict —
                        // weekly windows only, with its noise threshold).
                        // Static on purpose; a flicker overstated it. ALWAYS
                        // in the layout, invisible when pace is fine: a
                        // conditional flame shifted flame-rows right and
                        // broke the column alignment.
                        Image(systemName: "flame.fill")
                            .foregroundStyle(.orange)
                            .opacity(w.aheadOfPace == true ? 1 : 0)
                            .help("Burning faster than the window elapses")
                    }
                    if model.gamifiedRows {
                        // HP/MP semantics: the gauge shows what's LEFT.
                        // MP (blue) = the 5h session window, HP (red) = the
                        // weekly window — the statusline's vocabulary.
                        Text(label == "5h" ? "MP" : "HP")
                            .font(.caption).bold()
                            .foregroundStyle(label == "5h" ? Color.blue : Color.red)
                            .help(label == "5h" ? "Session mana (5h window left)"
                                                : "Weekly health (7d window left)")
                        GaugeBar(
                            remaining: GaugeMath.remaining(usedPct: w.pct),
                            color: label == "5h" ? .blue : .red
                        )
                    } else {
                        Text(label).foregroundStyle(.secondary)
                        Text("\(Int(w.pct))%")
                            .foregroundStyle(w.pct >= 100 ? .red : .primary)
                            .monospacedDigit()
                            .contentTransition(.numericText(value: w.pct))
                    }
                    // Full label in every mode — countdown plus the exact
                    // wall-clock reset ("3h 4m (21:07)"). The popover sizes
                    // to content now, so gamified rows no longer need the
                    // narrow countdown-only variant.
                    if let when = ResetLabel.label(w) {
                        Text(when).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
        // fixedSize: usage is the row's payload — grow the popup rather than
        // truncate a percentage to "2…" or a reset time to "3d 10…". The
        // email column is the one flexible (truncating) column left.
        .fixedSize()
        .activeBand(active)
    }

    /// The account's estimated 7-day spend as RPG gold, from the Usage
    /// tab's cached report — never triggers the multi-second scan itself.
    @ViewBuilder private func goldCell(_ account: Account) -> some View {
        if model.gamifiedRows,
           let row = usage.report?.accounts.first(where: { $0.number == account.number }) {
            let usd = Int(row.estimatedUSD)
            // Compact popup: "1,077" -> "1k" (rounded); full popup keeps
            // the exact figure. Text(verbatim:) so the compact string is
            // not re-formatted by LocalizedStringKey interpolation.
            Text(verbatim: model.compactRows && usd >= 1000
                 ? "💰\(Int((Double(usd) / 1000).rounded()))k"
                 : "💰\(usd.formatted())")
                .font(.caption).foregroundStyle(.yellow)
                .help("Estimated API-price spend, last \(usage.report?.days ?? 7) days — not a bill")
                .fixedSize()
                .activeBand(account.active)
        }
    }

    @ViewBuilder private func scopedCells(_ account: Account) -> some View {
        ForEach(account.usage?.scoped ?? [], id: \.name) { w in
            HStack(spacing: 3) {
                Image(systemName: "flame.fill")
                    .foregroundStyle(.orange)
                    .opacity(w.aheadOfPace == true ? 1 : 0)
                    .help("Burning faster than the window elapses")
                if model.gamifiedRows {
                    // Same RPG treatment as HP/MP: the per-model weekly
                    // limit as a purple gauge of what's LEFT.
                    Text(w.name ?? "?")
                        .font(.caption).bold()
                        .foregroundStyle(Color.purple)
                        .help("Model weekly limit left")
                    GaugeBar(remaining: GaugeMath.remaining(usedPct: w.pct),
                             color: .purple)
                } else {
                    Text(w.name ?? "?").foregroundStyle(.secondary)
                    Text("\(Int(w.pct))%")
                        .foregroundStyle(w.pct >= 100 ? .red : .primary)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: w.pct))
                }
            }
            .fixedSize()
            .activeBand(account.active)
        }
    }
}

private struct ActiveBand: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content.background {
            if active {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.22))
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
