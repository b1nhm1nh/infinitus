import SwiftUI

/// iCloud settings sync, in its own pane — it lived in Display, which is
/// the wrong home (user report 2026-08-30): it syncs notify flags and
/// engine config too, not just display prefs.
struct SyncPane: View {
    @ObservedObject var sync: SettingsSyncModel

    var body: some View {
        Form {
            Section("iCloud") {
                Toggle("Sync settings via iCloud Drive", isOn: $sync.enabled)
                    .help("Display prefs, custom themes, and set cswap "
                          + "engine settings travel through one JSON file "
                          + "in iCloud Drive/Limitless. Never credentials "
                          + "or push secrets. Last writer wins.")
                if let status = sync.status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
