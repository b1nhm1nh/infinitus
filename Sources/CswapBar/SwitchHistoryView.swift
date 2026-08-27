import SwiftUI
import AppKit
import CswapCore

/// Recent account switches, parsed from the switcher's log — same source and
/// format as the rumps "Switch history" submenu. The path mirrors
/// `switcher.backup_dir` (also home to the engine mutex).
struct SwitchHistoryView: View {
    @State private var entries: [String] = []
    @State private var expanded = false

    private static let logPath = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".claude-swap-backup/claude-swap.log")

    var body: some View {
        DisclosureGroup("Switch history", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 2) {
                if entries.isEmpty {
                    Text("No switches logged yet").foregroundStyle(.secondary)
                } else {
                    ForEach(entries, id: \.self) { Text($0).monospacedDigit() }
                }
                Button("Open full log…") {
                    NSWorkspace.shared.open(Self.logPath)
                }
                .font(.caption)
            }
            .font(.caption)
        }
        .onChange(of: expanded) {
            guard expanded else { return }
            let text = (try? String(contentsOf: Self.logPath, encoding: .utf8)) ?? ""
            entries = SwitchHistory.parse(text)
        }
    }
}
