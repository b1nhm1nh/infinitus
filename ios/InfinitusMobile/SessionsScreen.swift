import SwiftUI
import InfinitusCore
import InfinitusUI

/// The Sessions tab (#9 native shell): the Mac's live Claude Code
/// sessions as a native list. The second line — what a session is doing,
/// its todo capsule, the quiet timer — is the shared
/// `SessionProgressLine` the Mac popup's card draws.
struct SessionsScreen: View {
    @ObservedObject var model: MirrorModel
    @ObservedObject var progress: MobileSessionProgress
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Sessions")
                .refreshable { await model.refresh() }
                .navigationDestination(for: SessionDetail.self) { session in
                    SessionFeedScreen(session: session)
                }
        }
        // Same dev seam as `INFINITUS_TAB` — a headless simulator capture
        // can't tap a row, so a pid named here pushes straight to its feed.
        .onChange(of: fleetsWithSessions.isEmpty) { _, empty in
            guard !empty, path.isEmpty,
                  let pidText = ProcessInfo.processInfo.environment["INFINITUS_FEED_PID"],
                  let pid = Int(pidText),
                  let session = fleetsWithSessions
                      .flatMap({ $0.liveSessions?.sessions ?? [] })
                      .first(where: { $0.pid == pid })
            else { return }
            path.append(session)
        }
    }

    /// One section per fleet that has sessions to show — in practice
    /// only cswap's `liveSessions` is ever populated, but a fleet with
    /// none simply contributes no section.
    private var fleetsWithSessions: [MirrorFleetModel] {
        model.fleets.filter { !($0.liveSessions?.sessions?.isEmpty ?? true) }
    }

    @ViewBuilder private var content: some View {
        if !fleetsWithSessions.isEmpty {
            List {
                ForEach(fleetsWithSessions) { fleet in
                    let live = fleet.liveSessions!
                    Section {
                        ForEach(live.sessions ?? [], id: \.pid) { session in
                            NavigationLink(value: session) { row(session) }
                        }
                    } header: {
                        Text(model.fleets.count > 1
                             ? "\(fleet.fleetLabel?.engineName ?? fleet.engineID) — \(SessionSummary.tooltip(live))"
                             : SessionSummary.tooltip(live))
                    }
                }
            }
            .listStyle(.insetGrouped)
        } else if !model.fleets.isEmpty {
            ContentUnavailableView("No live sessions",
                                   systemImage: "brain",
                                   description: Text("Nothing is running on the "
                                                     + "Mac right now."))
        } else {
            ContentUnavailableView("Waiting for the fleet",
                                   systemImage: "antenna.radiowaves.left.and.right",
                                   description: Text("No snapshot yet — check "
                                                     + "Settings › Mac connection."))
        }
    }

    private func row(_ session: SessionDetail) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(color(for: session.status))
                .frame(width: 9, height: 9)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(progress.byPid[session.pid]?.name ?? repoName(session.cwd))
                        .font(.headline).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(session.status)
                        .font(.caption).foregroundStyle(.secondary)
                    Text(age(session.startedAt))
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                Text(shortCwd(session.cwd))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
                // Metadata line: branch · model · kind · pid · output tokens.
                Text(metadata(session))
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1)
                if let p = progress.byPid[session.pid], p.hasProgressSignal {
                    SessionProgressLine(progress: p)
                }
            }
        }
        .padding(.vertical, 4)
        .frame(minHeight: 44)
        .contextMenu {
            Button {
                UIPasteboard.general.string = session.cwd
            } label: {
                Label("Copy path", systemImage: "doc.on.doc")
            }
        }
    }

    /// Same colors the Mac's sessions card uses for each status.
    private func color(for status: String) -> Color {
        switch status {
        case "busy": return .orange
        case "waiting": return .yellow
        case "idle": return .green
        case "shell": return .blue
        default: return .gray
        }
    }

    private func repoName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private func shortCwd(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    private func metadata(_ session: SessionDetail) -> String {
        let p = progress.byPid[session.pid]
        var parts: [String] = []
        if let branch = p?.gitBranch { parts.append("⎇ \(branch)") }
        if let model = p?.model { parts.append(shortModel(model)) }
        if session.kind != "interactive", !session.kind.isEmpty { parts.append(session.kind) }
        parts.append("pid \(session.pid)")
        if let tokens = p?.outputTokens, tokens > 0 { parts.append("\(compact(tokens)) out") }
        return parts.joined(separator: " · ")
    }

    /// `claude-opus-4-1-20250805` → `opus 4.1`, `claude-fable-5` → `fable 5`.
    private func shortModel(_ id: String) -> String {
        var s = id
        if s.hasPrefix("claude-") { s.removeFirst("claude-".count) }
        if let dash = s.range(of: "-20", options: .backwards) { s = String(s[..<dash.lowerBound]) }
        let pieces = s.split(separator: "-")
        guard let family = pieces.first else { return id }
        let version = pieces.dropFirst().joined(separator: ".")
        return version.isEmpty ? String(family) : "\(family) \(version)"
    }

    private func compact(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6)
            : n >= 1000 ? "\(n / 1000)k" : "\(n)"
    }

    private func age(_ epochMs: Double) -> String {
        let started = Date(timeIntervalSince1970: epochMs / 1000)
        let s = Int(-started.timeIntervalSinceNow)
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }
}
