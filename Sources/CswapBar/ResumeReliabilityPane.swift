import SwiftUI
import CswapCore

/// Backlog item 6 addendum: surface the two Claude Code settings the resume
/// flow depends on — explain, show the EFFECTIVE value, offer the write.
/// Users without cmux have only the peer socket; for them these settings ARE
/// the reliability fix. A managed (org) value wins over the user file, so
/// the write buttons disable themselves rather than claim a success that
/// changes nothing.
@MainActor
final class ResumeReliabilityModel: ObservableObject {
    struct Row {
        let key: String
        let title: String
        let explanation: String
        let recommended: JSONValue
        var effective: ClaudeCodeConfig.Effective?
        var error: String?
    }

    @Published var rows: [Row] = [
        Row(
            key: "autoContinueAtUsageLimit",
            title: "Auto-continue at usage limit",
            explanation: "While off, a limit stop shows a dialog that blocks "
                + "cswap's resume nudge until you answer it at the keyboard.",
            recommended: .bool(true)
        ),
        Row(
            key: "crossSessionInbound",
            title: "Cross-session messages",
            explanation: "While unset, cswap's nudges are held for review "
                + "(its socket message carries no permission-mode attestation). "
                + "\"accept\" delivers them immediately — but any local process "
                + "that reaches a session's socket can then inject an "
                + "unreviewed user turn.",
            recommended: .string("accept")
        ),
    ]

    let config: ClaudeCodeConfig
    init(config: ClaudeCodeConfig = .standard()) { self.config = config }

    func load() {
        for i in rows.indices {
            rows[i].effective = try? config.effectiveValue(rows[i].key)
        }
    }

    func applyRecommended(_ index: Int) {
        do {
            try config.writeUserValue(rows[index].key, rows[index].recommended)
            rows[index].error = nil
            load()
        } catch {
            rows[index].error = "\(error)"
        }
    }
}

struct ResumeReliabilityPane: View {
    @ObservedObject var model: ResumeReliabilityModel

    var body: some View {
        Form {
            Text("These are Claude Code's settings, not cswap's. They decide "
                + "whether cswap's resume nudges actually reach a stopped "
                + "session. Changes apply to sessions started afterwards.")
                .font(.caption)
            ForEach(Array(model.rows.enumerated()), id: \.element.key) { index, row in
                Section(row.title) {
                    Text(row.explanation).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(currentLabel(row))
                        Spacer()
                        Button("Set \(row.recommended.editableText)") {
                            model.applyRecommended(index)
                        }
                        .disabled(row.effective?.source == .managed)
                    }
                    if row.effective?.source == .managed {
                        Text("Managed by your organization — the user file cannot override it.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if let err = row.error {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.load() }
    }

    private func currentLabel(_ row: ResumeReliabilityModel.Row) -> String {
        guard let effective = row.effective else { return "current: not set" }
        let origin = effective.source == .managed ? " (managed)" : ""
        return "current: \(effective.value.editableText)\(origin)"
    }
}
