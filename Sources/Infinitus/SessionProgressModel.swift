import Foundation
import CswapCore

/// Feeds the sessions popover's mini progress rows (issue #13 step 2).
/// Reads Claude Code's own session records + transcript tails — same
/// engine-isolation rule as ResumeService (never touches the engine).
@MainActor
final class SessionProgressModel: ObservableObject {
    @Published private(set) var byPid: [Int: SessionProgress] = [:]

    private let claudeDir = ClaudeSessions.configHome()
    private struct Stamp: Equatable { let size: Int; let mtime: Date }
    /// Cheap-skip cache, keyed by sessionId (a pid can flip sessions
    /// underneath us across refreshes; sessionId doesn't). A transcript
    /// whose size+mtime haven't moved since the last refresh is not
    /// re-parsed — the popover ticks every 10s and most sessions are
    /// between turns most of the time.
    private var stamps: [String: Stamp] = [:]
    private var cached: [String: SessionProgress] = [:]
    private var busy = false

    /// `sessions`: the engine's current per-session detail (busy-first,
    /// capped) — only those get matched to a transcript and read.
    func refresh(sessions: [SessionDetail]) {
        guard !busy else { return }
        guard !sessions.isEmpty else {
            byPid = [:]
            return
        }
        busy = true
        let claudeDir = claudeDir
        let stampsCopy = stamps
        let cachedCopy = cached
        Task.detached(priority: .utility) { [weak self] in
            let records = ClaudeSessions.list(claudeDir: claudeDir)
            let pairs = SessionProgress.match(sessions: sessions, records: records)
            var newByPid: [Int: SessionProgress] = [:]
            var newStamps = stampsCopy
            var newCached = cachedCopy
            for (session, record) in pairs {
                let url = Transcript.path(cwd: record.cwd, sessionId: record.sessionId, claudeDir: claudeDir)
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attrs?[.size] as? Int) ?? -1
                let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
                let stamp = Stamp(size: size, mtime: mtime)
                if stampsCopy[record.sessionId] == stamp, let previous = cachedCopy[record.sessionId] {
                    newByPid[session.pid] = previous
                    continue
                }
                let progress = SessionProgress.read(sessionId: record.sessionId, cwd: record.cwd,
                                                     claudeDir: claudeDir)
                newByPid[session.pid] = progress
                newStamps[record.sessionId] = stamp
                newCached[record.sessionId] = progress
            }
            await self?.finish(byPid: newByPid, stamps: newStamps, cached: newCached)
        }
    }

    private func finish(byPid: [Int: SessionProgress], stamps: [String: Stamp],
                        cached: [String: SessionProgress]) {
        busy = false
        self.byPid = byPid
        self.stamps = stamps
        self.cached = cached
    }
}
