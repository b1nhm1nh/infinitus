// Sources/Infinitus/StatsModel.swift
import Foundation
import InfinitusCore

/// The Stats tab's state: transcript facts + repo facts + event facts,
/// merged per day and folded into the four periods. Every scan runs off
/// the main actor; the first one backfills from everything on disk.
@MainActor
final class StatsModel: ObservableObject {
    @Published private(set) var days: [String: Stats.Day] = [:]
    @Published private(set) var summaries: [Stats.Period: Stats.Summary] = [:]
    @Published private(set) var scanning = false
    @Published private(set) var notes: [String] = []
    @Published private(set) var lastRefresh: Date?
    /// Set while the transcript chunk loop is running: "scanned n of N
    /// transcripts". The (separate, slower) repo scan doesn't report into
    /// this — see `refresh()`. Task 9's pane renders it.
    @Published private(set) var progress: String?

    let eventStore: EventStore
    private let repoScanner = RepoStatsScanner()
    /// Guards the repo scan against a later `refresh()` starting a second
    /// one while it's still running (git/gh can take minutes on a repo
    /// with a long history).
    private var repoScanRunning = false
    private var transcriptsFinished = false
    /// Rebuilt separately (transcript+event facts vs. repo facts) and
    /// combined into `notes` — the transcript chunk loop and the repo
    /// scan publish independently and must not stomp each other's half.
    private var transcriptNotes: [String] = []
    private var repoNotes: [String] = []

    init(eventStore: EventStore) { self.eventStore = eventStore }

    var bundle: Stats.Bundle { Stats.Bundle(days: days) }

    func loadIfNeeded() { if days.isEmpty, !scanning { refresh() } }

    func refreshIfStale(_ interval: TimeInterval = 300) {
        if lastRefresh.map({ Date().timeIntervalSince($0) > interval }) ?? true { refresh() }
    }

    private func recomputeNotes() { notes = transcriptNotes + repoNotes }

    /// Both the transcript loop and the repo scan can finish in either
    /// order; `scanning` only drops once both say they're done.
    private func markTranscriptsDone() {
        transcriptsFinished = true
        if !repoScanRunning { scanning = false }
    }

    private func markRepoScanDone() {
        repoScanRunning = false
        if transcriptsFinished { scanning = false }
    }

    /// A cold backfill (months of transcripts, first launch or an
    /// emptied cache) can take minutes; scanning the whole corpus in one
    /// shot would show nothing until it finished — and a slow repo (a
    /// long git history) must never block that. So this runs two
    /// independent loops:
    ///
    /// - The transcript chunk loop: `StatsScanner.scan` 300 files at a
    ///   time (newest first), merging in the once-loaded event days and
    ///   publishing `days`/`summaries`/`notes` after every chunk, until
    ///   nothing's left to parse. `progress` carries "scanned n of N
    ///   transcripts" while it runs.
    /// - The repo scan: started once, right after the first transcript
    ///   chunk (it needs that chunk's `cwds`), as its own detached task.
    ///   When it finishes — however long that takes — it merges its days
    ///   into whatever `days` currently holds and republishes.
    ///
    /// `scanning` stays true until both are done.
    func refresh() {
        guard !scanning else { return }
        scanning = true
        transcriptsFinished = false
        let store = eventStore
        let repos = repoScanner
        Task.detached(priority: .utility) {
            let calendar = Calendar.current
            let projectsDir = TokenRateScanner.defaultProjectsDir()
            let cacheURL = StatsScanner.defaultCacheURL()
            let events = await store.load()
            let eventDays = StatsEvents.days(events, calendar: calendar)
            var firstChunk = true
            var remaining = 1
            repeat {
                let transcripts = StatsScanner.scan(projectsDir: projectsDir, cacheURL: cacheURL,
                                                    calendar: calendar, limitFiles: 300) { done, total in
                    Task { @MainActor in self.progress = "scanned \(done) of \(total) transcripts" }
                }
                remaining = transcripts.remaining
                var merged = transcripts.days
                for (k, d) in eventDays { merged[k] = (merged[k] ?? Stats.Day()) + d }
                var chunkNotes: [String] = ["\(transcripts.files) transcripts"]
                if let first = events.first { chunkNotes.append("switches and limits since \(first.at.formatted(date: .abbreviated, time: .omitted))") }
                let folded = Dictionary(uniqueKeysWithValues: Stats.Period.allCases.map {
                    ($0, Stats.fold(days: merged, period: $0, calendar: calendar))
                })
                await MainActor.run {
                    self.days = merged
                    self.summaries = folded
                    self.transcriptNotes = chunkNotes
                    self.recomputeNotes()
                    self.lastRefresh = Date()
                }
                if firstChunk {
                    firstChunk = false
                    let cwds = transcripts.cwds
                    let started = await MainActor.run { () -> Bool in
                        guard !self.repoScanRunning else { return false }
                        self.repoScanRunning = true
                        return true
                    }
                    if started {
                        Task.detached(priority: .utility) {
                            let since = calendar.date(byAdding: .day, value: -400, to: Date())!
                            let repoOutcome = await repos.scan(cwds: cwds, since: since)
                            await MainActor.run {
                                var merged = self.days
                                for (k, d) in repoOutcome.days { merged[k] = (merged[k] ?? Stats.Day()) + d }
                                self.days = merged
                                self.summaries = Dictionary(uniqueKeysWithValues: Stats.Period.allCases.map {
                                    ($0, Stats.fold(days: merged, period: $0, calendar: calendar))
                                })
                                var built: [String] = ["\(repoOutcome.repos.count) repos"]
                                if !repoOutcome.skipped.isEmpty {
                                    built.append("no user.email — skipped: " + repoOutcome.skipped.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
                                }
                                built.append(repoOutcome.ghUsed ? "PRs from GitHub (gh)" : "PRs from git only — install and sign in to gh for opened/merged")
                                built.append(contentsOf: repoOutcome.notes)
                                self.repoNotes = built
                                self.recomputeNotes()
                                self.lastRefresh = Date()
                                self.markRepoScanDone()
                            }
                        }
                    }
                }
            } while remaining > 0 && !Task.isCancelled
            await MainActor.run {
                self.progress = nil
                self.markTranscriptsDone()
            }
        }
    }
}
