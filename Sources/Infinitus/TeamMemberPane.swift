import SwiftUI
import InfinitusCore

/// One teammate (spec §8.2, §9): period picker, the Stats tiles over
/// what they shared, their session index, and a transcript sheet.
struct TeamMemberPane: View {
    @ObservedObject var team: TeamModel
    let kid: String
    @State private var period: Stats.Period = .week
    @State private var openSession: TeamDocs.SessionRow?
    @State private var items: [SessionFeedItem]?

    private var member: TeamReader.Member? { team.reader?.members[kid] }
    private var summary: Stats.Summary? { team.reader?.summary(kid: kid, period: period) }

    var body: some View {
        Form {
            Section {
                Picker("Period", selection: $period) {
                    ForEach(Stats.Period.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if let s = summary {
                    Text("\(s.from) – \(s.to)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if let s = summary, s.total != Stats.Day() {
                StatsTiles(summary: s)
            } else {
                Section { Text("No stats shared for this period.").foregroundStyle(.secondary) }
            }
            if let m = member, !m.sessions.isEmpty {
                Section("Sessions") {
                    ForEach(m.sessions, id: \.id) { row in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name ?? row.project).bold()
                                Text("\(row.project) · \(row.engine) · \(row.busyMinutes) min busy · \(row.usd, format: .currency(code: "USD").precision(.fractionLength(2)))")
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Spacer()
                            if m.transcripts[row.id] != nil {
                                Button("Transcript") {
                                    items = nil
                                    openSession = row
                                    Task {
                                        let r = await team.transcript(kid: kid, session: row.id)
                                        if openSession?.id == row.id { items = r }
                                    }
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(member?.name ?? kid)
        .sheet(item: $openSession) { row in
            VStack(alignment: .leading, spacing: 0) {
                HStack { Text(row.name ?? row.project).font(.headline); Spacer(); Button("Close") { openSession = nil; items = nil } }.padding()
                if let items {
                    if items.isEmpty {
                        Spacer(); Text("Nothing to show").foregroundStyle(.secondary); Spacer()
                    } else {
                        List(Array(items.enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.kind.rawValue).font(.caption2).foregroundStyle(.secondary)
                                Text(item.text).font(.callout).textSelection(.enabled)
                            }
                        }
                    }
                } else {
                    Spacer(); HStack { Spacer(); ProgressView(); Spacer() }; Spacer()
                }
            }
            .frame(minWidth: 520, minHeight: 420)
        }
    }
}

/// `.sheet(item:)` needs an `Identifiable` row; `SessionRow.id` is the session id.
extension TeamDocs.SessionRow: Identifiable {}
