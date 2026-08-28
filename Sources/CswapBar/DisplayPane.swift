import SwiftUI
import CswapCore

/// App-local display preferences — the rumps Settings menu's four display
/// items (menubar.py `MenuBarSettings`), same choices and defaults.
struct DisplayPane: View {
    @ObservedObject var model: AppModel

    private let pctLabels = ["off": "None", "5h": "Session (5h)",
                             "7d": "Weekly (7d)", "both": "Both (5h · 7d)"]
    private let intervalLabels = [30: "30 seconds", 60: "60 seconds", 300: "5 minutes"]

    var body: some View {
        Form {
            Toggle("Show account name in menu bar", isOn: $model.showAccountName)
            Picker("Title percentage", selection: $model.titlePct) {
                ForEach(TitlePrefs.pctChoices, id: \.self) {
                    Text(pctLabels[$0] ?? $0).tag($0)
                }
            }
            Toggle("Show model limits in title", isOn: $model.titleScoped)
            Picker("Refresh interval", selection: $model.refreshInterval) {
                ForEach(TitlePrefs.refreshChoices, id: \.self) {
                    Text(intervalLabels[$0] ?? "\($0)s").tag($0)
                }
            }
            Section("Account order") {
                Text("Drag to rearrange. Slot numbers stay put; the accounts "
                     + "shift through them (aliases, backups, and history "
                     + "move with each account).")
                    .font(.caption).foregroundStyle(.secondary)
                List {
                    ForEach(model.accounts, id: \.number) { account in
                        HStack {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.tertiary)
                            Text("\(account.number)").monospacedDigit()
                                .foregroundStyle(.secondary)
                            Text(account.alias ?? account.email).lineLimit(1)
                            if account.active {
                                Text("active").font(.caption)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .onMove { from, to in
                        var order = model.accounts.map(\.number)
                        order.move(fromOffsets: from, toOffset: to)
                        model.reorder(order)
                    }
                }
                .frame(minHeight: CGFloat(model.accounts.count) * 28 + 16)
                if let err = model.reorderError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }
}
