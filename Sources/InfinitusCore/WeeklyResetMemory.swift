import Foundation

/// Cross-poll memory of each account's last-seen 7-day `resetsAt`
/// (issue #16). The engine reports an untouched window as bare
/// `"sevenDay": {"pct": 0}` for two different reasons it can't tell
/// apart: the window has genuinely never started (no reset to show),
/// or the window is mid-run and the engine just went quiet on the
/// reset time. Remembering the last resetsAt this app itself observed
/// lets the Ready cell tell them apart: still in the future -> the
/// window is running, keep showing it; past or never seen -> nothing
/// to show.
///
/// Fed by `UsageHistoryRecorder` (an actor) and read by MainActor
/// SwiftUI views, so this is a lock, not actor isolation — reads from
/// the UI stay synchronous.
public final class WeeklyResetMemory: @unchecked Sendable {
    public static let shared = WeeklyResetMemory()

    private let lock = NSLock()
    private var byEmail: [String: Date] = [:]

    /// Public so tests can exercise an isolated instance instead of the
    /// process-wide singleton.
    public init() {}

    /// Records a resetsAt seen for `email`'s 7-day window. Keeps the
    /// latest — a stale poll racing a fresher one must never regress it.
    public func note(email: String, resetsAt: Date) {
        lock.lock(); defer { lock.unlock() }
        if let existing = byEmail[email], existing >= resetsAt { return }
        byEmail[email] = resetsAt
    }

    /// The remembered resetsAt for `email`, only if still in the future
    /// (a past one means the window already rolled — nothing to show).
    public func futureReset(email: String, now: Date = Date()) -> Date? {
        lock.lock(); defer { lock.unlock() }
        guard let d = byEmail[email], d > now else { return nil }
        return d
    }

    /// Seeds from history samples (the existing usage-history JSONL) so
    /// a fresh launch doesn't forget what a prior session already saw.
    public func seed(from samples: [UsageSample]) {
        for s in samples {
            guard let ts = s.sevenDay?.resetsAt else { continue }
            note(email: s.email, resetsAt: Date(timeIntervalSince1970: ts))
        }
    }
}

/// The Ready cell's weekly-reset caption, decided as pure data so it's
/// testable without the singleton above. `remembered` is passed in
/// rather than read here.
public enum ReadyWeeklyCaption {
    /// - Parameters:
    ///   - pct/resetsAt/countdown/clock: the account's live sevenDay window.
    ///   - remembered: the last resetsAt this app has observed for the
    ///     account (`WeeklyResetMemory.futureReset`), or nil.
    ///   - compact: the popup's short vocabulary.
    /// - Returns: nil only when there's truly nothing to say (a positive
    ///   pct with no reset info at all — the pre-existing behavior).
    public static func text(pct: Double, resetsAt: String?, countdown: String?,
                            clock: String?, remembered: Date?,
                            now: Date = Date(), compact: Bool = false) -> String? {
        if let when = compact
            ? ResetLabel.compact(resetsAt: resetsAt, countdown: countdown, now: now)
            : ResetLabel.label(resetsAt: resetsAt, countdown: countdown,
                              clock: clock, now: now) {
            return when
        }
        guard pct <= 0 else { return nil }
        if let remembered, remembered > now {
            let iso = ISO8601DateFormatter().string(from: remembered)
            return compact
                ? ResetLabel.compact(resetsAt: iso, countdown: nil, now: now)
                : ResetLabel.label(resetsAt: iso, countdown: nil, clock: nil, now: now)
        }
        return compact ? "7d: first use" : "7d starts on first use"
    }
}
