import SwiftUI
import CswapCore

/// App-local display preferences — the rumps Settings menu's four display
/// items (menubar.py `MenuBarSettings`), same choices and defaults.
struct DisplayPane: View {
    @ObservedObject var model: AppModel
    @StateObject private var login = LoginItemModel()

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
            Picker("Gamification", selection: $model.gamification) {
                ForEach(GamificationStyle.allCases, id: \.rawValue) { style in
                    Text(style.displayName).tag(style.rawValue)
                }
            }
            Toggle("Compact rows (drop reset times in the popup)",
                   isOn: $model.compactRows)
            Toggle("Show menu bar icon", isOn: $model.menuBarIconShown)
                .help("Hide lasts until quit — it always returns on the next "
                      + "launch, so the app can never strand itself with no UI.")
            if !model.menuBarIconShown {
                Text("Icon hidden. The engine keeps running; get back here "
                     + "via this window or the pinned window.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Picker("Refresh interval", selection: $model.refreshInterval) {
                ForEach(TitlePrefs.refreshChoices, id: \.self) {
                    Text(intervalLabels[$0] ?? "\($0)s").tag($0)
                }
            }
            Toggle("Start at login",
                   isOn: Binding(get: { login.enabled }, set: { login.set($0) }))
                .help("Registers the app at its current path; moving the "
                      + "checkout breaks the login item until re-toggled.")
                .onAppear { login.refresh() }
            if let note = login.note {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
            Section("Account order") {
                Text("Drag to rearrange. Slot numbers stay put; the accounts "
                     + "shift through them (aliases, backups, and history "
                     + "move with each account). Type in the Name field to "
                     + "rename an account (sets its cswap alias, shown "
                     + "everywhere); clear it to go back to the email.")
                    .font(.caption).foregroundStyle(.secondary)
                List {
                    ForEach(model.accounts, id: \.number) { account in
                        HStack {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.tertiary)
                            Text("\(account.number)").monospacedDigit()
                                .foregroundStyle(.secondary)
                            RenameField(model: model, account: account)
                            Text(account.email).lineLimit(1)
                                .font(.caption).foregroundStyle(.secondary)
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


/// One account's editable display name. Local draft, committed on Enter or
/// focus loss — never on every keystroke (each commit is a `cswap alias`
/// subprocess + snapshot refresh).
private struct RenameField: View {
    @ObservedObject var model: AppModel
    let account: Account
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $draft)
            .textFieldStyle(.roundedBorder)
            .frame(width: 150)
            .focused($focused)
            .onAppear { draft = account.alias ?? "" }
            .onChange(of: account.alias) { draft = account.alias ?? "" }
            .onSubmit { commit() }
            .onChange(of: focused) { if !focused { commit() } }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard trimmed != (account.alias ?? "") else { return }
        model.rename(account.number, to: trimmed)
    }
}
