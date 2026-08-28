import SwiftUI
import CswapCore

/// Estimated spend dashboard (backlog item 4). The scan streams gigabytes
/// of transcripts (~seconds), so it runs on demand — first tab open and
/// the Refresh button — never on the snapshot timer.
@MainActor
final class UsageModel: ObservableObject {
    @Published var report: UsageReport?
    @Published var loading = false
    @Published var error: String?
    @Published var days = 7 { didSet { if days != oldValue { refresh() } } }

    private let cli: CswapCLI?

    init(cli: CswapCLI?) { self.cli = cli }

    func loadIfNeeded() {
        if report == nil && !loading { refresh() }
    }

    func refresh() {
        guard let cli, !loading else { return }
        loading = true
        error = nil
        let days = days
        Task {
            do {
                let r = try await cli.usageReport(days: days)
                self.report = r
            } catch { self.error = "\(error)" }
            self.loading = false
        }
    }
}

struct UsagePane: View {
    @ObservedObject var model: UsageModel

    var body: some View {
        Form {
            HStack {
                Picker("Window", selection: $model.days) {
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                }
                .frame(maxWidth: 220)
                Spacer()
                if model.loading {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Refresh") { model.refresh() }
                }
            }
            if let err = model.error {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            if let report = model.report {
                Section {
                    ForEach(Array(report.accounts.enumerated()), id: \.offset) { _, row in
                        bucketRow(row)
                    }
                    if let extra = report.unattributed {
                        bucketRow(extra, fallbackName: "before switch log")
                    }
                    LabeledContent("Total") {
                        Text(usd(report.estimatedTotalUSD)).bold().monospacedDigit()
                    }
                } header: {
                    Text("Estimated spend, last \(report.days) days")
                } footer: {
                    // The caveats ARE the feature — they carry the price-table
                    // date and the not-a-bill warning. Always rendered.
                    Text(report.caveats.joined(separator: " "))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else if model.loading {
                Text("Scanning transcripts…").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.loadIfNeeded() }
    }

    @ViewBuilder private func bucketRow(
        _ row: UsageReport.UsageBucket, fallbackName: String = "?"
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                if let n = row.number {
                    Text("\(n)").foregroundStyle(.secondary).monospacedDigit()
                }
                Text(row.alias ?? row.email ?? fallbackName).lineLimit(1)
                Spacer()
                Text(usd(row.estimatedUSD)).monospacedDigit()
            }
            HStack(spacing: 8) {
                Text("\(row.messages) msgs")
                Text("out \(TokenFormat.compact(row.output))")
                Text("cache \(TokenFormat.compact(row.cacheRead + row.cacheWrite))")
                if let top = row.models.first {
                    Text(top.model)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func usd(_ v: Double) -> String {
        String(format: "$%.2f", v)
    }
}
