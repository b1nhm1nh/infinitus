import SwiftUI
import AppKit
import CswapCore

@main
struct CswapBarApp: App {
    @StateObject private var model: AppModel
    @StateObject private var settingsModel: SettingsModel
    @StateObject private var reliabilityModel = ResumeReliabilityModel()

    init() {
        // Menu bar app: no Dock icon, no main window.
        NSApplication.shared.setActivationPolicy(.accessory)
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        _settingsModel = StateObject(wrappedValue: SettingsModel(cli: model.cli))
        model.startFeeds()
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
                Spacer()
                engineBadge
            }
            if let err = model.lastError {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
            if !model.eventLog.isEmpty {
                Divider()
                ForEach(model.eventLog.suffix(3), id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(minWidth: 440)
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
/// fake with monospaced padding (spec §4).
struct AccountGrid: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(model.accounts, id: \.number) { account in
                GridRow {
                    Text("\(account.number)")
                        .fontWeight(account.active ? .bold : .regular)
                    Button(account.alias ?? account.email) {
                        model.switchTo(account.number)
                    }
                    .buttonStyle(.plain)
                    .fontWeight(account.active ? .bold : .regular)
                    windowCell(account.usage?.fiveHour, label: "5h")
                    windowCell(account.usage?.sevenDay, label: "7d")
                    scopedCells(account)
                }
            }
        }
    }

    @ViewBuilder private func windowCell(_ w: UsageWindow?, label: String) -> some View {
        if let w {
            HStack(spacing: 3) {
                Text(label).foregroundStyle(.secondary)
                Text("\(Int(w.pct))%")
                    .foregroundStyle(w.pct >= 100 ? .red : .primary)
                    .monospacedDigit()
                if let countdown = w.countdown {
                    Text(countdown).font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private func scopedCells(_ account: Account) -> some View {
        ForEach(account.usage?.scoped ?? [], id: \.name) { w in
            HStack(spacing: 3) {
                Text(w.name ?? "?").foregroundStyle(.secondary)
                Text("\(Int(w.pct))%")
                    .foregroundStyle(w.pct >= 100 ? .red : .primary)
                    .monospacedDigit()
            }
        }
    }
}
