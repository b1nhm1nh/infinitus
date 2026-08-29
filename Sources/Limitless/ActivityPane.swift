import SwiftUI
import CswapCore

/// Switch history + the live engine event log — moved here from the popup
/// footer so the popup stays about the accounts.
struct ActivityPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Switch history") {
                SwitchHistoryView(cli: model.cli, startExpanded: true)
            }
            Section("Engine events") {
                if model.eventLog.isEmpty {
                    Text("No events yet this session").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.eventLog.suffix(30).enumerated().reversed()),
                            id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
