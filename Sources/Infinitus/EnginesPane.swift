import SwiftUI
import CswapCore

/// Claude provider pane: auto-switch control + the spec-driven cswap
/// settings. A top-level sidebar row, CodexBar-style (user 2026-08-30 —
/// providers sit IN the settings sidebar, not behind a nested split).
struct ClaudeEnginePane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: SettingsModel
    @ObservedObject var update: UpdateModel
    @ObservedObject var reliability: ResumeReliabilityModel

    var body: some View {
        Form {
            Section("Claude — cswap engine") {
                LabeledContent("Auto-switch") {
                    HStack {
                        stateText
                        Button(toggleTitle) { model.toggleEngine() }
                            .disabled(!togglable)
                    }
                }
                Text("Rotates Claude accounts before limits stall a session.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Mock data") {
                Toggle("Demo fleet (fabricated accounts)", isOn: $model.mockMode)
                Text("Five made-up accounts standing in for the engine — "
                     + "bravo burns ahead of pace, charlie is dead, rotate "
                     + "and reorder play along. Nothing reads or touches "
                     + "your real accounts; flipping this restarts the app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ResumeNudgesSection(service: model.resume)
            ResumeReliabilitySection(model: reliability)
            // Engine updates live WITH the engine (user 2026-08-30:
            // "move all of updates of engine to its engine setting");
            // About keeps the app's own release channel.
            Section("Engine updates") {
                Toggle("Update automatically", isOn: Binding(
                    get: { update.autoCheck && update.autoInstall },
                    set: { update.autoCheck = $0; update.autoInstall = $0 }))
                    .help("Watch PyPI daily; when a newer claude-swap "
                          + "appears, run `cswap upgrade` unattended and "
                          + "restart the engine.")
                LabeledContent {
                    HStack {
                        if update.updateAvailable {
                            Button("Update Now") { Task { await update.upgrade() } }
                                .disabled(update.busy)
                                .buttonStyle(.borderedProminent)
                        }
                        Button(update.busy ? "Checking…" : "Check for Updates…") {
                            Task { await update.check() }
                        }
                        .disabled(update.busy)
                    }
                } label: {
                    Text("cswap engine \(update.current ?? "—")")
                    if let latest = update.latest {
                        Text("latest on PyPI: \(latest)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let status = update.status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(update.updateAvailable ? Color.orange : .secondary)
                }
                Link(destination: releaseNotesURL) {
                    Label("Release notes", systemImage: "doc.text")
                }
                Link(destination: URL(string: "https://github.com/deathemperor/claude-swap")!) {
                    Label("Engine — claude-swap", systemImage: "gearshape.2")
                }
                if let output = update.upgradeOutput, !output.isEmpty {
                    DisclosureGroup("upgrade output") {
                        ScrollView {
                            Text(output)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 160)
                    }
                }
            }
            SettingsFormBody(model: settings)
        }
        .formStyle(.grouped)
        .task { await settings.load() }
        .onAppear { if update.current == nil { Task { await update.check() } } }
    }

    private var releaseNotesURL: URL {
        // Release notes live on the upstream repo (the PyPI package's home).
        if update.updateAvailable, let latest = update.latest {
            return URL(string: "https://github.com/realiti4/claude-swap/releases/tag/v\(latest)")!
        }
        return URL(string: "https://github.com/realiti4/claude-swap/releases")!
    }

    private var stateText: some View {
        Group {
            switch model.engineState {
            case .running: Text("running").foregroundStyle(.green)
            case .stopped: Text("stopped").foregroundStyle(.secondary)
            case .refused: Text("held elsewhere").foregroundStyle(.orange)
            case .backingOff(let s): Text("retrying in \(Int(s))s")
            case .schemaMismatch: Text("update the app")
            }
        }.font(.caption)
    }

    private var toggleTitle: String {
        if case .running = model.engineState { return "Stop" }
        if case .backingOff = model.engineState { return "Stop" }
        return "Start"
    }

    private var togglable: Bool {
        switch model.engineState {
        case .running, .stopped, .backingOff: return true
        case .refused, .schemaMismatch: return false
        }
    }
}

/// Codex provider pane: the app-native auth.json slot switcher.
struct CodexEnginePane: View {
    @StateObject private var codex = CodexEngineModel()

    var body: some View {
        Form {
            Section("Codex — OpenAI account slots") {
                if !codex.authPresent && codex.slots.isEmpty {
                    Text("No Codex CLI login found (\(CodexEngineModel.codexHome.path)/auth.json). "
                         + "Log in with `codex login`, then save it as a slot here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(codex.slots) { slot in
                    HStack {
                        Image(systemName: slot.active
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(slot.active ? .green : .secondary)
                        VStack(alignment: .leading) {
                            Text(slot.email ?? slot.mode)
                            if let plan = slot.plan {
                                Text(plan).font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if !slot.active {
                            Button("Switch") { codex.switchTo(slot.id) }
                        }
                        Button(role: .destructive) {
                            codex.remove(slot.id)
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Forget this slot (the stored login is deleted)")
                    }
                }
                Button("Save current Codex login as a slot") {
                    codex.addCurrent()
                }
                if let status = codex.status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Text("Slots are whole-file snapshots of auth.json; switching "
                     + "saves the live login back first. Manual only — no "
                     + "usage tracking or auto-switch for Codex yet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Planned") {
                Text("Gemini CLI and opencode store logins the same "
                     + "file-swap way — candidates if ever needed.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .onAppear { codex.reload() }
    }
}

extension EngineSupervisor.State {
    /// Sidebar live-dot: only a genuinely running engine counts.
    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// CLIProxyAPI provider pane (#8): the second engine. Talks only to the
/// proxy's Management API with a keychain-held key; never its files.
struct CLIProxyEnginePane: View {
    @ObservedObject var model: AppModel
    @State private var baseURL = ""
    @State private var key = ""
    @State private var probe: String?
    @State private var probing = false

    private var proxyFleets: [FleetState] {
        model.fleets.filter { $0.engineID == CLIProxyEngine.engineID }
    }

    var body: some View {
        Form {
            Section("Engines") {
                Toggle("cswap (credential swap under Claude Code)", isOn: $model.cswapEnabled)
                Toggle("CLIProxyAPI (rotates behind its own endpoint)", isOn: $model.cliproxyEnabled)
                    .disabled(!model.cliproxyKeyPresent && !model.cliproxyEnabled)
                if model.cswapEnabled && model.cliproxyEnabled {
                    Text("Both engines are on. cswap swaps the credential under "
                         + "Claude Code; the proxy rotates behind its own endpoint — "
                         + "for the same accounts they fight. Run one per account set.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("Flipping an engine restarts the app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("CLIProxyAPI — management API") {
                TextField("Base URL", text: $baseURL, prompt: Text(CLIProxyEngine.defaultBaseURL.absoluteString))
                    .textFieldStyle(.roundedBorder)
                SecureField("Management key", text: $key,
                            prompt: Text(model.cliproxyKeyPresent ? "•••••••• (stored in keychain)" : "remote-management.secret-key"))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(probing ? "Testing…" : "Test connection") { test() }
                        .disabled(probing)
                    Button("Save & restart") {
                        model.saveCLIProxy(baseURL: baseURL.isEmpty ? model.cliproxyBaseURL : baseURL,
                                           key: key.isEmpty ? (Keychain.read(account: model.cliproxyBaseURL) ?? "") : key)
                    }
                    .buttonStyle(.borderedProminent)
                    if model.cliproxyKeyPresent {
                        Button("Forget key") { model.saveCLIProxy(baseURL: model.cliproxyBaseURL, key: "") }
                    }
                }
                if let probe {
                    Text(probe).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let err = model.engineErrors[CLIProxyEngine.engineID] {
                    Text(err).font(.caption).foregroundStyle(.orange)
                }
                if let caveat = model.fleetCaveats[CLIProxyEngine.engineID] {
                    Text(caveat).font(.caption).foregroundStyle(.orange)
                }
                Text("The key is the proxy's remote-management.secret-key; it is kept "
                     + "in the keychain and sent as a bearer header. Infinitus never "
                     + "reads the proxy's config or credential files.")
                    .font(.caption).foregroundStyle(.secondary)
                if let proxy = model.cliProxy {
                    Text(DetectionLines.proxyLine(proxy, live: model.cliProxyLive))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            ForEach(proxyFleets) { fleet in
                CLIProxyFleetSection(fleet: fleet, model: model)
            }
            if model.cliproxyEnabled, proxyFleets.isEmpty {
                Section("Accounts") {
                    Button("Add Claude account (sign in via browser)…") {
                        model.addOAuthAccount(engineID: CLIProxyEngine.engineID, provider: .claude)
                    }
                    .disabled(model.addingFirstAccount)
                    if let msg = model.firstAccountMessage {
                        Text(msg).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { baseURL = model.cliproxyBaseURL }
    }

    private func test() {
        let urlString = baseURL.isEmpty ? model.cliproxyBaseURL : baseURL
        guard let url = URL(string: urlString) else { probe = "bad URL"; return }
        let k = key.isEmpty ? (Keychain.read(account: model.cliproxyBaseURL) ?? "") : key
        guard !k.isEmpty else { probe = "enter the management key first"; return }
        probing = true
        Task {
            let engine = CLIProxyEngine(baseURL: url, managementKey: k)
            do {
                let p = try await engine.probe()
                probe = "reachable — \(p.credentialFiles) credential file\(p.credentialFiles == 1 ? "" : "s")"
                    + (p.strategy.map { ", routing \($0)" } ?? "")
            } catch {
                probe = (error as? EngineError)?.errorDescription ?? "\(error)"
            }
            probing = false
        }
    }
}

/// One proxy fleet's credentials with the full action set (hold,
/// switch-as-priority, rename, remove, add) — the settings-side twin
/// of the popup rows.
struct CLIProxyFleetSection: View {
    @ObservedObject var fleet: FleetState
    @ObservedObject var model: AppModel

    var body: some View {
        Section("\(fleet.provider.displayName) — \(fleet.accounts.count) credential\(fleet.accounts.count == 1 ? "" : "s")") {
            ForEach(fleet.accounts, id: \.number) { a in
                HStack {
                    Image(systemName: a.active ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(a.active ? .green : .secondary)
                    VStack(alignment: .leading) {
                        Text(a.alias ?? a.email)
                        Text(statusLine(a)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !a.active, fleet.capabilities.contains(.switch) {
                        Button("Switch") { fleet.switchTo(a.number) }
                            .help("Raise this credential to the top priority tier")
                    }
                    if fleet.capabilities.contains(.hold) {
                        Button(a.disabled == true ? "Unhold" : "Hold") {
                            fleet.setRotation(a.number, enabled: a.disabled == true)
                        }
                    }
                    if a.usageStatus == "relogin_required", fleet.capabilities.contains(.addOAuth) {
                        Button("Re-login…") { fleet.startRelogin(a) }
                    }
                    if fleet.capabilities.contains(.remove) {
                        Button(role: .destructive) {
                            fleet.remove(a.number)
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Delete this credential file from the proxy")
                    }
                }
            }
            if fleet.capabilities.contains(.addOAuth), fleet.provider == .claude || fleet.provider == .codex {
                Button("Add \(fleet.provider.displayName) account (sign in via browser)…") {
                    model.addOAuthAccount(engineID: fleet.engineID, provider: fleet.provider)
                }
                .disabled(model.addingFirstAccount)
                if let msg = model.firstAccountMessage {
                    Text(msg).font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private func statusLine(_ a: Account) -> String {
        var parts: [String] = []
        if a.disabled == true { parts.append("held") }
        parts.append(a.usageStatus == "relogin_required" ? "re-login needed" : a.usageStatus)
        if let plan = a.plan { parts.append(plan) }
        if let pct = a.usage?.fiveHour?.pct { parts.append("5h \(Int(pct))%") }
        if let pct = a.usage?.sevenDay?.pct { parts.append("7d \(Int(pct))%") }
        return parts.joined(separator: " · ")
    }
}
