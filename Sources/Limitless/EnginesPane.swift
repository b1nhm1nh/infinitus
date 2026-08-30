import SwiftUI
import CswapCore

/// The revamped engine settings (user, 2026-08-30): one pane for every
/// account engine Limitless drives. Claude (the cswap engine) is primary;
/// Codex is the first sibling — file-mode slot switching handled by the
/// app itself (CodexEngineModel), no cswap involvement.
struct EnginesPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: SettingsModel
    @StateObject private var codex = CodexEngineModel()

    var body: some View {
        Form {
            Section {
                LabeledContent("Auto-switch") {
                    HStack {
                        engineStateText
                        Button(engineToggleTitle) { model.toggleEngine() }
                            .disabled(!engineTogglable)
                    }
                }
                Text("Rotates Claude accounts before limits stall a session. "
                     + "Every knob below is a cswap engine setting.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Label("Claude — cswap engine", systemImage: "bolt.fill")
            }

            // The spec-driven cswap settings, unchanged underneath.
            SettingsFormBody(model: settings)

            Section {
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
            } header: {
                Label("Codex — OpenAI", systemImage: "circle.hexagongrid")
            }

            Section {
                Text("Gemini CLI and opencode use the same file-swap shape — "
                     + "planned, not built.")
                    .font(.caption).foregroundStyle(.tertiary)
            } header: {
                Label("More engines", systemImage: "ellipsis.circle")
            }
        }
        .formStyle(.grouped)
        .onAppear { codex.reload() }
    }

    private var engineStateText: some View {
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

    private var engineToggleTitle: String {
        if case .running = model.engineState { return "Stop" }
        if case .backingOff = model.engineState { return "Stop" }
        return "Start"
    }

    private var engineTogglable: Bool {
        switch model.engineState {
        case .running, .stopped, .backingOff: return true
        case .refused, .schemaMismatch: return false
        }
    }
}
