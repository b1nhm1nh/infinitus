import SwiftUI
import InfinitusCore

/// One teammate on the phone (spec §9): period picker, the same stat
/// tiles StatsScreen draws (via Stats.Presentation — the layout is
/// re-typed here, NOT extracted from StatsScreen, which another stream
/// owns), their session index, and a transcript list.
struct TeamMemberScreen: View {
    let model: MirrorModel
    let kid: String
    let name: String
    @State private var period: Stats.Period = .week
    @State private var reply: TeamMirror.MemberReply?
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Picker("Period", selection: $period) {
                    ForEach(Stats.Period.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if let s = reply?.summary { Text("\(s.from) – \(s.to)").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
            if let s = reply?.summary, s.total != Stats.Day() {
                ForEach(Stats.Presentation.groups(s)) { group in
                    Section(group.id) {
                        ForEach(group.tiles) { tile in
                            LabeledContent(tile.id) {
                                HStack(spacing: 6) {
                                    Text(tile.value).monospacedDigit()
                                    if let delta = tile.delta { Text(delta).font(.caption2).foregroundStyle(.tertiary).monospacedDigit() }
                                }
                            }
                        }
                    }
                }
                effortSection("Where the effort went", Stats.Presentation.activityRows(s))
                effortSection("By model", Stats.Presentation.modelRows(s))
            } else if reply != nil {
                Section { Text("No stats shared for this period.").foregroundStyle(.secondary) }
            }
            if let r = reply, !r.sessions.isEmpty {
                let transcriptIds = Set(r.transcripts)
                Section("Sessions") {
                    ForEach(r.sessions, id: \.id) { row in
                        if transcriptIds.contains(row.id) {
                            NavigationLink { TeamTranscriptScreen(kid: kid, session: row) } label: { sessionRow(row) }
                        } else {
                            sessionRow(row)
                        }
                    }
                }
            }
            if let error { Section { Text(error).font(.caption).foregroundStyle(.orange) } }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: period) { await load() }
        .overlay { if reply == nil && error == nil { ProgressView() } }
    }

    private func load() async {
        let want = period
        error = nil
        do {
            let r = try await NetworkFleetMirror.shared.teamMember(kid: kid, period: want)
            guard !Task.isCancelled, want == period else { return }
            reply = r
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func sessionRow(_ row: TeamDocs.SessionRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.name ?? row.project).bold()
            Text("\(row.project) · \(row.engine) · \(row.busyMinutes) min busy · \(row.usd, format: .currency(code: "USD").precision(.fractionLength(2)))")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func effortSection(_ title: String, _ rows: [Stats.Presentation.Row]) -> some View {
        Section(title) {
            if rows.isEmpty { Text("Nothing yet this period").font(.caption).foregroundStyle(.tertiary) }
            ForEach(rows) { r in
                LabeledContent {
                    Text("\(r.usdText) · \(r.minutesText)").monospacedDigit()
                } label: {
                    Text(r.id)
                    Text("\(r.count) stretches · \(r.tokensText) tokens\(r.cachedSuffixText)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A teammate's shared transcript: plain rows (kind + text). Not
/// SessionFeedScreen's chat rows — those belong to another stream's file.
struct TeamTranscriptScreen: View {
    let kid: String
    let session: TeamDocs.SessionRow
    @State private var items: [SessionFeedItem]?
    @State private var error: String?

    var body: some View {
        Group {
            if let items {
                if items.isEmpty {
                    ContentUnavailableView("Nothing to show", systemImage: "text.bubble",
                                           description: Text(error ?? "The transcript is empty or not readable by you."))
                } else {
                    List(Array(items.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.kind.rawValue).font(.caption2).foregroundStyle(.secondary)
                            Text(item.text).font(.callout).textSelection(.enabled)
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(session.name ?? session.project)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { items = try await NetworkFleetMirror.shared.teamTranscript(kid: kid, session: session.id) }
            catch { self.error = error.localizedDescription; items = [] }
        }
    }
}
