import XCTest
@testable import InfinitusCore

final class ReadyWeeklyCaptionTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func testEngineResetWins() {
        // Engine sends a resetsAt (e.g. a non-zero pct) — that wins,
        // no need to consult the remembered value at all.
        let iso = ISO8601DateFormatter().string(from: now.addingTimeInterval(3600))
        let text = ReadyWeeklyCaption.text(pct: 40, resetsAt: iso, countdown: nil,
                                           clock: nil, remembered: now.addingTimeInterval(60),
                                           now: now)
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.contains("1h"))
    }

    func testZeroPctWithFutureRememberedResetShowsIt() {
        // Issue #16: the engine goes quiet on resetsAt at 0%, but this
        // app already saw one still in the future — show it.
        let remembered = now.addingTimeInterval(2 * 3600)
        let text = ReadyWeeklyCaption.text(pct: 0, resetsAt: nil, countdown: nil,
                                           clock: nil, remembered: remembered, now: now)
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.contains("2h"), "expected a 2h countdown, got \(text!)")
    }

    func testZeroPctWithPastRememberedResetFallsBack() {
        // The remembered window already rolled over — nothing to show.
        let remembered = now.addingTimeInterval(-3600)
        let text = ReadyWeeklyCaption.text(pct: 0, resetsAt: nil, countdown: nil,
                                           clock: nil, remembered: remembered, now: now)
        XCTAssertEqual(text, "7d starts on first use")
    }

    func testZeroPctWithNoRememberedResetFallsBack() {
        let text = ReadyWeeklyCaption.text(pct: 0, resetsAt: nil, countdown: nil,
                                           clock: nil, remembered: nil, now: now)
        XCTAssertEqual(text, "7d starts on first use")
    }

    func testCompactUsesShortFallback() {
        let text = ReadyWeeklyCaption.text(pct: 0, resetsAt: nil, countdown: nil,
                                           clock: nil, remembered: nil, now: now, compact: true)
        XCTAssertEqual(text, "7d: first use")
    }

    func testPositivePctWithNoResetInfoStaysNil() {
        // Pre-existing behavior: a positive pct with no reset data at
        // all still shows nothing (not the "first use" fallback, which
        // is reserved for untouched windows).
        let text = ReadyWeeklyCaption.text(pct: 40, resetsAt: nil, countdown: nil,
                                           clock: nil, remembered: nil, now: now)
        XCTAssertNil(text)
    }
}

final class WeeklyResetMemoryTests: XCTestCase {
    func testFutureResetIsRemembered() {
        let mem = WeeklyResetMemory()
        let now = Date(timeIntervalSince1970: 1_000_000)
        mem.note(email: "a@example.com", resetsAt: now.addingTimeInterval(3600))
        XCTAssertNotNil(mem.futureReset(email: "a@example.com", now: now))
    }

    func testPastResetIsNotReturned() {
        let mem = WeeklyResetMemory()
        let now = Date(timeIntervalSince1970: 1_000_000)
        mem.note(email: "a@example.com", resetsAt: now.addingTimeInterval(-3600))
        XCTAssertNil(mem.futureReset(email: "a@example.com", now: now))
    }

    func testNoteNeverRegressesToAnOlderTimestamp() {
        let mem = WeeklyResetMemory()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let later = now.addingTimeInterval(7200)
        mem.note(email: "a@example.com", resetsAt: later)
        mem.note(email: "a@example.com", resetsAt: now.addingTimeInterval(3600))
        XCTAssertEqual(mem.futureReset(email: "a@example.com", now: now), later)
    }
}
