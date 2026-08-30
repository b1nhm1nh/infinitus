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
