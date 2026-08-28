import XCTest
import CswapCore

private func account(_ json: String) throws -> Account {
    try JSONDecoder().decode(Account.self, from: Data(json.utf8))
}

private let base = #""number": 1, "email": "dev@example.com", "organizationName": "o", "organizationUuid": "u", "isOrganization": true, "active": true"#

final class TitleFormatterTests: XCTestCase {
    func testNoAccountIsBareIcon() {
        XCTAssertEqual(TitleFormatter.format(account: nil, prefs: TitlePrefs()), "⇄")
    }

    func testBothPctsWithLocalPart() throws {
        let a = try account(#"{\#(base), "usageStatus": "ok", "usage": {"fiveHour": {"pct": 12.4}, "sevenDay": {"pct": 88.6, "resetsAt": "2999-01-01T00:00:00Z"}}}"#)
        XCTAssertEqual(TitleFormatter.format(account: a, prefs: TitlePrefs()), "⇄ dev · 12% · 89%")
    }

    func testAliasWinsAndModesFilter() throws {
        let a = try account(#"{\#(base), "alias": "work", "usageStatus": "ok", "usage": {"fiveHour": {"pct": 50}, "sevenDay": {"pct": 70, "resetsAt": "2999-01-01T00:00:00Z"}}}"#)
        XCTAssertEqual(TitleFormatter.format(account: a, prefs: TitlePrefs(titlePct: "5h")), "⇄ work · 50%")
        XCTAssertEqual(TitleFormatter.format(account: a, prefs: TitlePrefs(titlePct: "7d")), "⇄ work · 70%")
        XCTAssertEqual(TitleFormatter.format(account: a, prefs: TitlePrefs(showAccountName: false, titlePct: "off")), "⇄")
    }

    func testPassedWeeklyResetRollsToZero() throws {
        let a = try account(#"{\#(base), "usageStatus": "ok", "usage": {"sevenDay": {"pct": 100, "resetsAt": "2020-01-01T00:00:00Z"}}}"#)
        XCTAssertEqual(TitleFormatter.format(account: a, prefs: TitlePrefs(showAccountName: false, titlePct: "7d")), "⇄ 0%")
    }

    func testScopedSegmentsNamedAndRolled() throws {
        let a = try account(#"{\#(base), "usageStatus": "ok", "usage": {"scoped": [{"pct": 100, "name": "Fable", "resetsAt": "2999-01-01T00:00:00Z"}, {"pct": 100, "name": "Old", "resetsAt": "2020-01-01T00:00:00Z"}]}}"#)
        let prefs = TitlePrefs(showAccountName: false, titlePct: "off", titleScoped: true)
        XCTAssertEqual(TitleFormatter.format(account: a, prefs: prefs), "⇄ Fable 100% · Old 0%")
    }

    func testSentinelRowShowsNameOnly() throws {
        let a = try account(#"{\#(base), "usageStatus": "no_credentials", "usage": null}"#)
        XCTAssertEqual(TitleFormatter.format(account: a, prefs: TitlePrefs()), "⇄ dev")
    }
}

final class WeeklyRollTests: XCTestCase {
    func testDisplayResetAdvancesToNextBoundary() throws {
        let w = try JSONDecoder().decode(UsageWindow.self, from: Data(#"{"pct": 40, "resetsAt": "2026-01-01T00:00:00Z"}"#.utf8))
        let now = WeeklyRoll.parse("2026-01-09T00:00:00Z")!  // 8 days past reset
        XCTAssertEqual(WeeklyRoll.displayReset(w, now: now), WeeklyRoll.parse("2026-01-15T00:00:00Z"))
        XCTAssertEqual(WeeklyRoll.displayPct(w, now: now), 0.0)
    }

    func testFutureAndMissingResetsUnchanged() throws {
        let w = try JSONDecoder().decode(UsageWindow.self, from: Data(#"{"pct": 40}"#.utf8))
        XCTAssertEqual(WeeklyRoll.displayPct(w, now: Date()), 40.0)
        XCTAssertNil(WeeklyRoll.displayReset(w, now: Date()))
    }
}

final class SwitchHistoryTests: XCTestCase {
    func testParsesAndReversesTrimmedStamps() {
        let log = """
        2026-06-27 02:06:11,123 - INFO - Switched from account 3 to 1
        junk line
        2026-06-27 03:00:00,456 - INFO - Switched from account 1 to 2
        """
        XCTAssertEqual(SwitchHistory.parse(log),
                       ["1 → 2   2026-06-27 03:00", "3 → 1   2026-06-27 02:06"])
    }

    func testLimitKeepsMostRecent() {
        let log = (1...15).map { "2026-06-27 0\($0 % 10):00:00 - Switched from account 1 to 2" }
            .joined(separator: "\n")
        XCTAssertEqual(SwitchHistory.parse(log).count, 10)
    }
}

final class SentinelNotesTests: XCTestCase {
    func testOkIsNil() { XCTAssertNil(SentinelNotes.note(for: "ok")) }

    func testKnownNotesVerbatim() {
        XCTAssertEqual(SentinelNotes.note(for: "token_expired"),
                       "token expired — refresh deferred this pass; retries automatically")
        XCTAssertEqual(SentinelNotes.note(for: "api_key"), "API key (no quota)")
    }

    func testUnknownStatusHumanized() {
        XCTAssertEqual(SentinelNotes.note(for: "brand_new_state"), "brand new state")
    }
}

final class ResetLabelTests: XCTestCase {
    private func window(_ json: String) throws -> UsageWindow {
        try JSONDecoder().decode(UsageWindow.self, from: Data(json.utf8))
    }
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func testSameDayCountdownAndClock() throws {
        let w = try window(#"{"pct": 10, "resetsAt": "2026-01-01T14:30:00Z"}"#)
        let now = WeeklyRoll.parse("2026-01-01T12:15:00Z")!
        XCTAssertEqual(ResetLabel.label(w, now: now, calendar: utc), "2h 15m (14:30)")
    }

    func testCrossDayShowsDate() throws {
        let w = try window(#"{"pct": 10, "resetsAt": "2026-01-03T08:00:00Z"}"#)
        let now = WeeklyRoll.parse("2026-01-01T08:00:00Z")!
        XCTAssertEqual(ResetLabel.label(w, now: now, calendar: utc), "2d 0h (Jan 3 08:00)")
    }

    func testMinutesOnly() throws {
        let w = try window(#"{"pct": 10, "resetsAt": "2026-01-01T12:59:30Z"}"#)
        let now = WeeklyRoll.parse("2026-01-01T12:15:00Z")!
        XCTAssertEqual(ResetLabel.label(w, now: now, calendar: utc), "44m (12:59)")
    }

    func testFallsBackToFeedStrings() throws {
        let w = try window(#"{"pct": 10, "countdown": "3h 2m", "clock": "15:30"}"#)
        XCTAssertEqual(ResetLabel.label(w), "3h 2m (15:30)")
    }

    func testNilWindowNil() {
        XCTAssertNil(ResetLabel.label(nil))
    }
}
