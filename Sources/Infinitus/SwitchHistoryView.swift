import SwiftUI
import AppKit
import CswapCore

/// Recent account switches via `cswap history --json` — the engine parses
/// its own log; this view never touches engine-internal files (the log
/// path for the "open" button comes from the same JSON).
/// Numbers resolve to the accounts' display names; times render as
/// "20:20" / "yesterday 17:21" / "Aug 28 06:44" (user 2026-08-30:
/// raw "3 → 5   2026-08-30 20:20" rows floating mid-pane).
struct SwitchHistoryView: View {
    let cli: CswapCLI?
    var names: [Int: String] = [:]
    @State private var entries: [SwitchHistoryList.Switch] = []
    @State private var logPath: String?

    var body: some View {
        if entries.isEmpty {
            Text("No switches logged yet").foregroundStyle(.secondary)
                .onAppear(perform: load)
        } else {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, sw in
                HStack(spacing: 6) {
                    Text(name(sw.from))
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Text(name(sw.to))
                    Spacer()
                    Text(when(sw.at))
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            if let logPath {
                Button("Open full log…") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
                }
                .font(.caption)
            }
        }
    }

    private func name(_ number: Int) -> String {
        names[number] ?? "account \(number)"
    }

    /// "2026-08-30 20:20" from the engine, local time.
    private static let parse: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private func when(_ raw: String) -> String {
        guard let date = Self.parse.date(from: raw) else { return raw }
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return time }
        if Calendar.current.isDateInYesterday(date) { return "yesterday \(time)" }
        return date.formatted(.dateTime.month(.abbreviated).day()) + " \(time)"
    }

    private func load() {
        guard let cli else { return }
        Task {
            guard let list = try? await cli.history(limit: 20) else { return }
            entries = list.switches
            logPath = list.logPath
        }
    }
}
