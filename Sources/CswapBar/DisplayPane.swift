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
            Section("Row theme") {
                ForEach(GamificationStyle.allCases, id: \.rawValue) { style in
                    GamificationCard(
                        style: style,
                        selected: model.gamification == style.rawValue
                    ) { model.gamification = style.rawValue }
                }
            }
            Toggle("Compact popup (hide actions, event log, and history)",
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


/// One selectable gamification style, previewed as the REAL popup row —
/// same columns, fonts, and numbers as the live active-account row, so the
/// choice is what-you-see-is-what-you-get.
private struct GamificationCard: View {
    let style: GamificationStyle
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    preview.fixedSize()
                }
                HStack {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    Text(style.displayName).font(.caption)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.3),
                                  lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    // Mirrors AccountGrid's cells with the numbers from a real row:
    // session 21% used (79% left, resets 4h 8m), weekly 68% used (32%
    // left, ahead of pace), Fable 74%, $1,131 spent.
    @ViewBuilder private var preview: some View {
        HStack(spacing: 12) {
            Text("4").fontWeight(.bold).foregroundStyle(Color.accentColor)
            Text("papaya").fontWeight(.bold)
            switch style {
            case .off:
                HStack(spacing: 3) {
                    Text("5h").foregroundStyle(.secondary)
                    Text("21%").monospacedDigit()
                    Text("4h 8m (22:09)").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 3) {
                    Image(systemName: "flame.fill").foregroundStyle(.orange)
                    Text("7d").foregroundStyle(.secondary)
                    Text("68%").monospacedDigit()
                    Text("5d 9h (Sep 4 03:59)").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 3) {
                    Text("$").foregroundStyle(.secondary)
                    Text("74%").monospacedDigit()
                }
            case .rpg:
                HStack(spacing: 3) {
                    Text("MP").font(.caption).bold().foregroundStyle(Color.blue)
                    GaugeBar(remaining: 79, color: .blue)
                    Text("4h 8m (22:09)").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 3) {
                    Image(systemName: "flame.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .orange)
                    Text("HP").font(.caption).bold().foregroundStyle(Color.red)
                    GaugeBar(remaining: 32, color: .red)
                    Text("5d 9h (Sep 4 03:59)").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 3) {
                    Text("$").font(.caption).bold().foregroundStyle(Color.green)
                    GaugeBar(remaining: 26, color: .green)
                }
            case .movie:
                HStack(spacing: 3) {
                    Text("🎬").font(.caption)
                    GaugeBar(remaining: 79, color: .yellow)
                    Text("4h 8m (22:09)").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 3) {
                    Image(systemName: "popcorn.fill").foregroundStyle(.orange)
                    Text("🎞").font(.caption)
                    GaugeBar(remaining: 32, color: .indigo)
                    Text("5d 9h (Sep 4 03:59)").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 3) {
                    Text("🎟").font(.caption).bold().foregroundStyle(Color.green)
                    GaugeBar(remaining: 26, color: .green)
                }
            }
            HStack(spacing: 3) {
                switch style {
                case .rpg:
                    Image(systemName: "flame.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .orange)
                    Text("Fable").font(.caption).bold().foregroundStyle(Color.purple)
                    GaugeBar(remaining: 26, color: .purple)
                case .movie:
                    Image(systemName: "popcorn.fill").foregroundStyle(.orange)
                    Text("★ Fable").font(.caption).bold().foregroundStyle(Color.orange)
                    GaugeBar(remaining: 26, color: .orange)
                case .off:
                    Image(systemName: "flame.fill").foregroundStyle(.orange)
                    Text("Fable").foregroundStyle(.secondary)
                    Text("74%").monospacedDigit()
                }
            }
            if style == .rpg {
                Text(verbatim: "💰1,131").font(.caption).foregroundStyle(.yellow)
            } else if style == .movie {
                Text(verbatim: "💵1,131").font(.caption).foregroundStyle(.yellow)
            }
        }
    }
}
