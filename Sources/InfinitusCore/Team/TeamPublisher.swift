import Foundation
import Crypto

/// Spec §7: turns this machine's Claude Code files into the member's
/// documents and publishes them through `TeamClient`. `collect` is the
/// pure half (Task 4); publishing, chunking state and re-share follow
/// (Task 6).
public struct TeamPublisher {
    /// One transcript file to chunk: the session's own, or one of its
    /// sub-agents'.
    public struct TranscriptSource: Equatable {
        public var session: String
        public var agent: String?
        public var url: URL
        public init(session: String, agent: String?, url: URL) { self.session = session; self.agent = agent; self.url = url }

        /// `<session>` or `<session>/subagents/<agent>` — the cursor key
        /// and the store directory (spec §4.3, `TeamKinds`).
        public var key: String { agent.map { "\(session)/subagents/\($0)" } ?? session }
        public func chunkPath(seq: Int) -> String { "transcripts/\(key)/\(seq).jsonl" }
    }

    public struct Collected: Equatable {
        public var days: [String: Stats.Day] = [:]
        public var sessions: [TeamDocs.SessionRow] = []
        public var transcripts: [TranscriptSource] = []
        public init() {}
    }

    /// The same rule `StatsScanner.scan` walks with: `<project>/<sid>.jsonl`
    /// is a session, `<project>/<sid>/subagents/<agent>.jsonl` one of its
    /// sub-agents. For Codex files the "project dir" is a date; callers
    /// ignore it there.
    public static func transcriptIdentity(_ path: String) -> (session: String, agent: String?, projectDir: String) {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        if parent.lastPathComponent == "subagents" {
            let sessionDir = parent.deletingLastPathComponent()
            return (sessionDir.lastPathComponent, url.deletingPathExtension().lastPathComponent,
                    sessionDir.deletingLastPathComponent().lastPathComponent)
        }
        return (url.deletingPathExtension().lastPathComponent, nil, parent.lastPathComponent)
    }

    /// Folds the scan's per-file entries minus excluded projects: days
    /// (Stats v2 `+`), one row per session (sub-agents summed in), and
    /// the Claude Code transcript files to chunk. Codex files are
    /// chunked by nobody — only their days and session row travel.
    public static func collect(entries: [String: StatsScanner.FileEntry], exclusions: TeamExclusions) -> Collected {
        var out = Collected()
        var rows: [String: TeamDocs.SessionRow] = [:]
        for (path, entry) in entries.sorted(by: { $0.key < $1.key }) {
            let identity = transcriptIdentity(path)
            let claude = entry.engine == Stats.Engine.claude.rawValue
            if exclusions.excludes(cwd: entry.cwd, projectDir: claude ? identity.projectDir : nil) { continue }
            let days = entry.daysWithOpenStretch()
            for (key, day) in days { out.days[key] = (out.days[key] ?? Stats.Day()) + day }

            let project = entry.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            var row = rows[identity.session]
                ?? TeamDocs.SessionRow(id: identity.session, project: project ?? String(identity.projectDir.split(separator: "-").last ?? ""), engine: entry.engine)
            // A sub-agent file seen first carries no cwd; the session's own file names the project.
            if let project, identity.agent == nil { row.project = project }
            for t in entry.state.firstAt.values {
                row.startedAt = row.startedAt == 0 ? Int(t) : min(row.startedAt, Int(t))
            }
            for t in entry.state.lastAt.values { row.endedAt = max(row.endedAt, Int(t)) }
            for day in days.values {
                row.waitingMinutes += Int(day.waitingSeconds / 60)
                row.usd += day.usd
                for (label, tally) in day.activities {
                    let minutes = Int(tally.seconds / 60)
                    row.activities[label, default: 0] += minutes
                    row.busyMinutes += minutes
                }
            }
            if identity.agent != nil { row.subagents += 1 }
            rows[identity.session] = row
            if claude { out.transcripts.append(TranscriptSource(session: identity.session, agent: identity.agent, url: URL(fileURLWithPath: path))) }
        }
        for key in out.days.keys { out.days[key]!.finalizePeak() }
        out.sessions = rows.values.sorted { $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt > $1.startedAt }
        return out
    }
}
