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
        let reliabilityModel = ResumeReliabilityModel()
        _reliabilityModel = StateObject(wrappedValue: reliabilityModel)
        // Warm the multi-second transcript scan at launch so the Usage tab
        // and the gamified gold column open onto data, not a spinner.
        usage.loadIfNeeded()
        appDelegate.makeStatusItem = { [weak appDelegate] in
            appDelegate?.statusHolder = StatusItemHolder(
                model: model, usage: usage,
                settingsView: {
                    AnyView(SettingsRoot(
                        model: model, settingsModel: settingsModel,
                        reliabilityModel: reliabilityModel,
                        notifyModel: notifyModel, usageModel: usage))
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
            SettingsRoot(model: model, settingsModel: settingsModel,
                         reliabilityModel: reliabilityModel,
                         notifyModel: notifyModel, usageModel: usageModel)
        }
    }
}

/// The five settings panes. Shared by the Settings scene (the standard
/// app-menu path, unreachable for an accessory app with no app menu) and
/// the controller-owned window the popup's Settings… button opens.
struct SettingsRoot: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settingsModel: SettingsModel
    @ObservedObject var reliabilityModel: ResumeReliabilityModel
    @ObservedObject var notifyModel: NotifyModel
    @ObservedObject var usageModel: UsageModel

    var body: some View {
        TabView {
            SettingsPane(model: settingsModel)
                .tabItem { Label("cswap", systemImage: "gearshape") }
            ResumeReliabilityPane(model: reliabilityModel)
                .tabItem { Label("Resume reliability", systemImage: "arrow.clockwise") }
            DisplayPane(model: model)
                .tabItem { Label("Display", systemImage: "menubar.rectangle") }
            NotifyPane(model: notifyModel)
                .tabItem { Label("Away push", systemImage: "antenna.radiowaves.left.and.right") }
            UsagePane(model: usageModel)
                .tabItem { Label("Usage", systemImage: "chart.bar") }
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
            if let err = model.lastError {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
            if let notifyErr = Notifier.lastAuthError {
                Text(notifyErr).font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
            if !model.eventLog.isEmpty {
                Divider()
                ForEach(model.eventLog.suffix(3), id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            SwitchHistoryView()
            Divider()
            HStack {
                Button("Settings…") { model.showSettings?() }
                Button {
                    model.showPinned?()
                } label: {
                    Label("Pin", systemImage: "pin")
                }
                .help("Open this as a window that stays put — the popup "
                      + "always closes when you click elsewhere.")
                Spacer()
                Button("Quit") { model.shutdown() }   // engine stops first
            }
        }
        .padding(12)
        .frame(minWidth: 560)
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
                    if w.aheadOfPace == true {
                        // Token-burn flame: usage is meaningfully ahead of the
                        // window's elapsed time (the feed's pace verdict —
                        // weekly windows only, with its noise threshold).
                        // Static on purpose; a flicker overstated it.
                        Image(systemName: "flame.fill")
                            .foregroundStyle(.orange)
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
                    if !model.compactRows,
                       let when = model.gamifiedRows
                           ? ResetLabel.short(w) : ResetLabel.label(w) {
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
            Text("💰\(Int(row.estimatedUSD))")
                .font(.caption).foregroundStyle(.yellow)
                .help("Estimated API-price spend, last \(usage.report?.days ?? 7) days — not a bill")
                .fixedSize()
                .activeBand(account.active)
        }
    }

    @ViewBuilder private func scopedCells(_ account: Account) -> some View {
        ForEach(account.usage?.scoped ?? [], id: \.name) { w in
            HStack(spacing: 3) {
                if w.aheadOfPace == true {
                    Image(systemName: "flame.fill")
                        .foregroundStyle(.orange)
                        .help("Burning faster than the window elapses")
                }
                Text(w.name ?? "?").foregroundStyle(.secondary)
                Text("\(Int(w.pct))%")
                    .foregroundStyle(w.pct >= 100 ? .red : .primary)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: w.pct))
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
