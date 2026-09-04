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
    /// Set while a multi-chunk backfill is running: "scanned n of N
    /// transcripts". Task 9's pane renders it; for now it rides in `notes`.
    @Published private(set) var progress: String?

    let eventStore: EventStore
    private let repoScanner = RepoStatsScanner()

    init(eventStore: EventStore) { self.eventStore = eventStore }

    var bundle: Stats.Bundle { Stats.Bundle(days: days) }

    func loadIfNeeded() { if days.isEmpty, !scanning { refresh() } }

    func refreshIfStale(_ interval: TimeInterval = 300) {
        if lastRefresh.map({ Date().timeIntervalSince($0) > interval }) ?? true { refresh() }
    }

    /// A cold backfill (months of transcripts, first launch or an
    /// emptied cache) can take minutes; scanning the whole corpus in one
    /// shot would show nothing until it finished. Instead this chunks the
    /// transcript scan 300 files at a time (newest first — today's data
    /// lands before last year's), publishing merged days/summaries after
    /// every chunk, until `StatsScanner.scan` reports nothing left to
    /// parse. `progress` carries "scanned n of N transcripts" while a
    /// chunk is running so callers can show it.
    func refresh() {
        guard !scanning else { return }
        scanning = true
        let store = eventStore
        let repos = repoScanner
        Task.detached(priority: .utility) {
            let calendar = Calendar.current
            let projectsDir = TokenRateScanner.defaultProjectsDir()
            let cacheURL = StatsScanner.defaultCacheURL()
            var remaining = 1
            repeat {
                let transcripts = StatsScanner.scan(projectsDir: projectsDir, cacheURL: cacheURL,
                                                    calendar: calendar, limitFiles: 300) { done, total in
                    Task { @MainActor in self.progress = "scanned \(done) of \(total) transcripts" }
                }
                remaining = transcripts.remaining
                let since = calendar.date(byAdding: .day, value: -400, to: Date())!
                let repoOutcome = await repos.scan(cwds: transcripts.cwds, since: since)
                let events = await store.load()
                var merged = transcripts.days
                for (k, d) in repoOutcome.days { merged[k] = (merged[k] ?? Stats.Day()) + d }
                for (k, d) in StatsEvents.days(events, calendar: calendar) { merged[k] = (merged[k] ?? Stats.Day()) + d }
                var notes: [String] = ["\(transcripts.files) transcripts · \(repoOutcome.repos.count) repos"]
                if !repoOutcome.skipped.isEmpty {
                    notes.append("no user.email — skipped: " + repoOutcome.skipped.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
                }
                notes.append(repoOutcome.ghUsed ? "PRs from GitHub (gh)" : "PRs from git only — install and sign in to gh for opened/merged")
                if let first = events.first { notes.append("switches and limits since \(first.at.formatted(date: .abbreviated, time: .omitted))") }
                let folded = Dictionary(uniqueKeysWithValues: Stats.Period.allCases.map {
                    ($0, Stats.fold(days: merged, period: $0, calendar: calendar))
                })
                await MainActor.run {
                    self.days = merged
                    self.summaries = folded
                    self.notes = notes
                    self.lastRefresh = Date()
                }
            } while remaining > 0 && !Task.isCancelled
            await MainActor.run {
                self.progress = nil
                self.scanning = false
            }
        }
    }
}
