import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// iCloud settings sync, in its own pane — it lived in Display, which is
/// the wrong home (user report 2026-08-30): it syncs notify flags and
/// engine config too, not just display prefs.
struct SyncPane: View {
    @ObservedObject var sync: SettingsSyncModel
    @ObservedObject var app: AppModel
    /// The LAN server publishes its own state (port, failures), so the
    /// pane observes it directly — AppModel doesn't republish it.
    @ObservedObject private var server: MirrorServer

    init(sync: SettingsSyncModel, app: AppModel) {
        self.sync = sync
        self.app = app
        _server = ObservedObject(wrappedValue: app.mirrorServer)
    }

    var body: some View {
        Form {
            Section("iCloud") {
                Toggle("Sync settings via iCloud Drive", isOn: $sync.enabled)
                    .help("Display prefs, custom themes, and set cswap "
                          + "engine settings travel through one JSON file "
                          + "in iCloud Drive/Infinitus. Never credentials "
                          + "or push secrets. Last writer wins.")
                if let status = sync.status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
            // The phone companion's transport (#9): this Mac serves its
            // last fleet snapshot to InfinitusMobile over the LAN.
            Section("Phone companion (LAN)") {
                Toggle("Serve the fleet to my phone on this network",
                       isOn: $app.mirrorLANEnabled)
                    .help("Advertises this Mac as _infinitus._tcp and answers "
                          + "GET /snapshot with the same fleet snapshot the "
                          + "menu bar shows.")
                if let status = server.status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Text("Anyone on this network can read the snapshot — there "
                     + "is no password. It carries account aliases, emails "
                     + "and usage estimates; never tokens or push secrets.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // Manual path for machines outside the iCloud account
            // (user request 2026-08-30). Same snapshot, same scope.
            Section("File") {
                LabeledContent("Settings as a file") {
                    HStack {
                        Button("Export…") { runExportPanel() }
                        Button("Import…") { runImportPanel() }
                    }
                }
                Text("The same settings the iCloud sync carries — display "
                     + "prefs, custom themes, cswap engine config. Never "
                     + "credentials or push secrets.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func runExportPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "infinitus-settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await sync.export(to: url) }
    }

    private func runImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await sync.importConfig(from: url) }
    }
}
