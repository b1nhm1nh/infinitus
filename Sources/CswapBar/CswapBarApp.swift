import SwiftUI
import AppKit
import CswapCore

@main
struct CswapBarApp: App {
    @StateObject private var model: AppModel
    @StateObject private var settingsModel: SettingsModel
    @StateObject private var reliabilityModel = ResumeReliabilityModel()
    @StateObject private var notifyModel: NotifyModel

    init() {
        // Menu bar app: no Dock icon, no main window.
        NSApplication.shared.setActivationPolicy(.accessory)
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        _settingsModel = StateObject(wrappedValue: SettingsModel(cli: model.cli))
        _notifyModel = StateObject(wrappedValue: NotifyModel(cli: model.cli))
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
        MenuBarExtra(model.title) {
            MenuContent(model: model)
                .task { await model.refreshSnapshot() }
        }
        .menuBarExtraStyle(.window)

        Settings {
            TabView {
                SettingsPane(model: settingsModel)
                    .tabItem { Label("cswap", systemImage: "gearshape") }
                ResumeReliabilityPane(model: reliabilityModel)
                    .tabItem { Label("Resume reliability", systemImage: "arrow.clockwise") }
                DisplayPane(model: model)
                    .tabItem { Label("Display", systemImage: "menubar.rectangle") }
                NotifyPane(model: notifyModel)
                    .tabItem { Label("Away push", systemImage: "antenna.radiowaves.left.and.right") }
            }
            .frame(width: 520, height: 480)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AccountGrid(model: model)
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
            Button("Quit") { NSApplication.shared.terminate(nil) }
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

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
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
                    // usage numbers and reset times never do.
                    .frame(maxWidth: 230, alignment: .leading)
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
                    }
                }
            }
        }
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
                    Text(label).foregroundStyle(.secondary)
                    Text("\(Int(w.pct))%")
                        .foregroundStyle(w.pct >= 100 ? .red : .primary)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: w.pct))
                    if let when = resetLabel(w) {
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

    private func resetLabel(_ w: UsageWindow) -> String? {
        ResetLabel.label(w)
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
