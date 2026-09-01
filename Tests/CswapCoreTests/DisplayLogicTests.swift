import XCTest
import CswapCore

private func account(_ json: String) throws -> Account {
    try JSONDecoder().decode(Account.self, from: Data(json.utf8))
}

private let base = #""number": 1, "email": "dev@example.com", "organizationName": "o", "organizationUuid": "u", "isOrganization": true, "active": true"#
private let base2 = #""number": 4, "email": "dontsuckmyemail@gmail.com", "organizationName": "o", "organizationUuid": "u", "isOrganization": true, "active": true"#

final class TitleFormatterTests: XCTestCase {
    func testNoAccountIsBareIcon() {
        XCTAssertEqual(TitleFormatter.format(account: nil, prefs: TitlePrefs()), "⇄")
    }

    func testBothPctsWithLocalPart() throws {
        let a = try account(#"{\#(base), "usageStatus": "ok", "usage": {"fiveHour": {"pct": 12.4}, "sevenDay": {"pct": 88.6, "resetsAt": "2999-01-01T00:00:00Z"}}}"#)
        XCTAssertEqual(TitleFormatter.format(account: a, prefs: TitlePrefs()), "⇄ dev · 12·89%")
    }

    func testLongNamesAreCapped() throws {
        // The menu bar EVICTS items that stop fitting (and persists the
        // eviction), so the title must never grow past a compact width.
        let a = try account(#"{\#(base2), "usageStatus": "ok", "usage": {"fiveHour": {"pct": 5}, "sevenDay": {"pct": 49, "resetsAt": "2999-01-01T00:00:00Z"}}}"#)
        XCTAssertEqual(TitleFormatter.format(account: a, prefs: TitlePrefs()),
                       "⇄ dontsuckm… · 5·49%")
    }

    func testRemainingFlipsEveryWindowKind() throws {
        // titleRemaining counts what's LEFT; the flip covers 5h, 7d,
        // and scoped windows alike (menu-bar setting, 2026-08-30).
        let a = try account(#"{\#(base), "usageStatus": "ok", "usage": {"fiveHour": {"pct": 12.4}, "sevenDay": {"pct": 88.6, "resetsAt": "2999-01-01T00:00:00Z"}, "scoped": [{"pct": 30, "name": "Opus", "resetsAt": "2999-01-01T00:00:00Z"}]}}"#)
        XCTAssertEqual(
            TitleFormatter.format(account: a,
                                  prefs: TitlePrefs(titleScoped: true,
                                                    titleRemaining: true)),
            "⇄ dev · 88·11% · Opus 70%")
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
    func testDecodesHistoryJSON() throws {
        let json = #"{"schemaVersion":1,"switches":[{"from":3,"to":1,"at":"2026-06-27 02:06"}],"logPath":"/tmp/x.log"}"#
        let list = try JSONDecoder().decode(SwitchHistoryList.self, from: Data(json.utf8))
        XCTAssertEqual(list.switches.first?.from, 3)
        XCTAssertEqual(list.switches.first?.at, "2026-06-27 02:06")
        XCTAssertEqual(list.logPath, "/tmp/x.log")
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

    func testShortFormsStayOneLine() {
        XCTAssertEqual(SentinelNotes.short(for: "relogin_required"), "re-login needed")
        XCTAssertEqual(SentinelNotes.short(for: "token_expired"), "token expired — retrying")
        // Already-short notes fall through to the full text.
        XCTAssertEqual(SentinelNotes.short(for: "api_key"), "API key (no quota)")
        XCTAssertEqual(SentinelNotes.short(for: "no_credentials"), "no credentials")
        XCTAssertNil(SentinelNotes.short(for: "ok"))
        XCTAssertEqual(SentinelNotes.short(for: "brand_new_state"), "brand new state")
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

    func testShortDropsTheWallClock() throws {
        let w = try window(#"{"pct": 10, "resetsAt": "2026-01-01T14:30:00Z"}"#)
        let now = WeeklyRoll.parse("2026-01-01T12:15:00Z")!
        XCTAssertEqual(ResetLabel.short(w, now: now, calendar: utc), "2h 15m")
    }

    func testShortKeepsCountdownOnlyFeeds() throws {
        let w = try window(#"{"pct": 10, "countdown": "3h 2m"}"#)
        XCTAssertEqual(ResetLabel.short(w), "3h 2m")
        XCTAssertNil(ResetLabel.short(nil))
    }

    func testNilWindowNil() {
        XCTAssertNil(ResetLabel.label(nil))
    }
}

final class AccountVitalsTests: XCTestCase {
    private func usage(_ json: String) throws -> Usage {
        try JSONDecoder().decode(Usage.self, from: Data(json.utf8))
    }

    func testNilAndHealthyAreAlive() throws {
        XCTAssertFalse(AccountVitals.isDead(nil))
        let u = try usage(#"{"fiveHour":{"pct":99.9},"sevenDay":{"pct":50}}"#)
        XCTAssertFalse(AccountVitals.isDead(u))
    }

    func testAnyExhaustedWindowIsDead() throws {
        XCTAssertTrue(AccountVitals.isDead(try usage(#"{"fiveHour":{"pct":100}}"#)))
        XCTAssertTrue(AccountVitals.isDead(try usage(#"{"sevenDay":{"pct":100.0}}"#)))
        XCTAssertTrue(AccountVitals.isDead(
            try usage(#"{"scoped":[{"pct":100,"name":"Fable"}]}"#)))
    }

    func testSpentCreditAloneIsAlive() throws {
        // Spent usage credit = no overflow buffer; the subscription
        // windows still have headroom, so the account is NOT dead.
        let u = try usage(
            #"{"sevenDay":{"pct":10},"spend":{"used":200.29,"limit":200,"pct":100,"currency":"USD"}}"#)
        XCTAssertFalse(AccountVitals.isDead(u))
        XCTAssertNil(AccountVitals.cause(u))
    }
}

final class RowThemeTests: XCTestCase {
    func testMinimalCustomThemeDecodesWithDefaults() throws {
        let json = #"[{"id":"x","name":"X"}]"#
        let themes = try JSONDecoder().decode([RowTheme].self, from: Data(json.utf8))
        XCTAssertEqual(themes.first?.sessionLabel, "5h")
        XCTAssertEqual(themes.first?.deadMarker, "💀")
        XCTAssertFalse(themes.first?.plain ?? true)
    }

    func testTemplateJSONParses() throws {
        let themes = try JSONDecoder().decode(
            [RowTheme].self, from: Data(RowTheme.templateJSON.utf8))
        XCTAssertEqual(themes.first?.id, "synthwave")
        XCTAssertEqual(themes.first?.sessionColor, "#ff2d95")
    }

    func testBrokenFileYieldsEmpty() {
        XCTAssertEqual(RowTheme.loadCustom(
            from: URL(fileURLWithPath: "/nonexistent/themes.json")), [])
    }
}

final class ResetLabelCompactTests: XCTestCase {
    func testCompactSameDayAndCrossDay() throws {
        // Pinned mid-day instant: with Date() this flaked inside the 90
        // minutes before UTC midnight, when now+90m honestly crosses the
        // day and the label rightly grows a date (seen 2026-08-30).
        let now = ISO8601DateFormatter().date(from: "2026-01-10T10:00:00Z")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let f = ISO8601DateFormatter()
        let sameDay = now.addingTimeInterval(90 * 60)
        let w1 = try JSONDecoder().decode(UsageWindow.self, from: Data(
            #"{"pct": 40, "resetsAt": "\#(f.string(from: sameDay))"}"#.utf8))
        let s1 = ResetLabel.compact(w1, now: now, calendar: cal)
        XCTAssertNotNil(s1)
        XCTAssertTrue(s1!.hasPrefix("1h"), s1!)
        XCTAssertFalse(s1!.contains(" "), s1!)
        let farDay = now.addingTimeInterval(5 * 86400 + 7 * 3600)
        let w2 = try JSONDecoder().decode(UsageWindow.self, from: Data(
            #"{"pct": 40, "resetsAt": "\#(f.string(from: farDay))"}"#.utf8))
        let s2 = ResetLabel.compact(w2, now: now, calendar: cal)
        XCTAssertTrue(s2!.hasPrefix("5d"), s2!)
        XCTAssertTrue(s2!.contains("·"), s2!)
    }
}

final class RecoveryCountdownTests: XCTestCase {
    func testHoursMinutesSeconds() {
        let now = Date(timeIntervalSince1970: 0)
        let secs: Double = 7384   // 2h 3m 4s
        let until = now.addingTimeInterval(secs)
        XCTAssertEqual(RecoveryCountdown.label(until: until, now: now), "02:03:04")
    }

    func testDaysPrefix() {
        let now = Date(timeIntervalSince1970: 0)
        let secs: Double = 95592   // 1d 2h 33m 12s
        let until = now.addingTimeInterval(secs)
        XCTAssertEqual(RecoveryCountdown.label(until: until, now: now), "1d 02:33:12")
    }

    func testClampsAtZeroOnceDue() {
        let now = Date(timeIntervalSince1970: 1000)
        let until = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(RecoveryCountdown.label(until: until, now: now), "00:00:00")
    }
}
