import SwiftUI
import InfinitusCore

/// Switch history + the live engine event log — moved here from the popup
/// footer so the popup stays about the accounts.
struct ActivityPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Switch history") {
                SwitchHistoryView(cli: model.cli, names: accountNames)
            }
            Section("Engine events") {
                if model.eventLog.isEmpty {
                    Text("No events yet this session").foregroundStyle(.secondary)
                } else {
                    ForEach(model.eventLog.suffix(30).reversed()) { entry in
                        HStack(spacing: 6) {
                            Image(systemName: entry.icon)
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(width: 16)
                            Text(entry.text)
                            Spacer()
                            Text(entry.at, format: .dateTime.hour().minute())
                                .font(.caption).monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Alias (or the email's local part) per account number.
    private var accountNames: [Int: String] {
        Dictionary(uniqueKeysWithValues: model.accounts.map { a in
            (a.number, a.alias ?? String(a.email.split(separator: "@").first ?? "?"))
        })
    }
}
