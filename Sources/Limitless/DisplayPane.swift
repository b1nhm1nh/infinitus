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
            Toggle("Menu bar counts remaining, not used",
                   isOn: $model.titleRemaining)
                .help("Flips the menu bar percentages to what's left. "
                      + "The popup gauges already count remaining.")
            Picker("Popup layout", selection: Binding(
                get: { model.popupLayout },
                set: { value in
                    withAnimation(.easeInOut(duration: 0.3)) { model.popupLayout = value }
                })) {
                Text("Wide rows").tag("wide")
                Text("Stacked cards").tag("stacked")
            }
            Picker("Popup size", selection: $model.popupTextSize) {
                Text("Default").tag("default")
                Text("Large").tag("large")
                Text("Extra large").tag("xlarge")
                Text("Huge").tag("huge")
            }
            Section("Popup transparency") {
                glassSlider("Transparency", value: $model.glassFocused)
                Text("Higher is clearer — the backdrop shows through with "
                     + "a soft glass blur. Lower is frostier. One value "
                     + "for every state; the popup never shifts with "
                     + "focus.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Compact popup (one-line accounts, icon controls)",
                   isOn: $model.compactRows)
            Toggle("Hide popup actions (status chips stay)",
                   isOn: $model.footerActionsHidden)
                .help("Removes the buttons from the popup. Everything they "
                      + "did is in the menu bar icon's right-click menu.")
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
            Toggle("Keep Mac awake while sessions are working",
                   isOn: $model.keepAwake)
                .help("Holds a power assertion (caffeinate -i, in-process) "
                      + "whenever any Claude Code session is mid-turn. The "
                      + "display may still sleep; the machine won't.")
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
                            if let plan = account.plan {
                                Text(plan)
                                    .font(.caption2)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                    .foregroundStyle(.secondary)
                            }
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

    private func glassSlider(_ label: String,
                             value: Binding<Double>) -> some View {
        LabeledContent(label) {
            HStack {
                Slider(value: value, in: 0...1)
                    .frame(width: 180)
                Text("\(Int(value.wrappedValue * 100))%")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
        }
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
