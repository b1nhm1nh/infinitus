import SwiftUI
import AppKit
import CswapCore

/// Recent account switches via `cswap history --json` — the engine parses
/// its own log; this view never touches engine-internal files (the log
/// path for the "open" button comes from the same JSON).
struct SwitchHistoryView: View {
    let cli: CswapCLI?
    @State private var entries: [String] = []
    @State private var logPath: String?
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("Switch history", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 2) {
                if entries.isEmpty {
                    Text("No switches logged yet").foregroundStyle(.secondary)
                } else {
                    ForEach(entries, id: \.self) { Text($0).monospacedDigit() }
                }
                if let logPath {
                    Button("Open full log…") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
                    }
                    .font(.caption)
                }
            }
            .font(.caption)
        }
        .onChange(of: expanded) {
            guard expanded, let cli else { return }
            Task {
                guard let list = try? await cli.history() else { return }
                entries = list.switches.map { "\($0.from) → \($0.to)   \($0.at)" }
                logPath = list.logPath
            }
        }
    }
}
