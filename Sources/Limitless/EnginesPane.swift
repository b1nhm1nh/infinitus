import SwiftUI
import CswapCore

/// Claude provider pane: auto-switch control + the spec-driven cswap
/// settings. A top-level sidebar row, CodexBar-style (user 2026-08-30 —
/// providers sit IN the settings sidebar, not behind a nested split).
struct ClaudeEnginePane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: SettingsModel

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
            SettingsFormBody(model: settings)
        }
        .formStyle(.grouped)
        .task { await settings.load() }
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
            Section("Planned providers") {
                Text("Gemini, OpenCode, Cursor, Copilot — same file-swap "
                     + "shape, not built yet.")
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
