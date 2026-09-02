import XCTest
@testable import InfinitusCore

final class LiveSessionsDecodeTests: XCTestCase {
    func testBreakdownDecodes() throws {
        let json = #"{"busy":2,"idle":3,"waiting":1,"shell":1,"unknown":2,"total":9}"#
        let live = try JSONDecoder().decode(LiveSessions.self, from: Data(json.utf8))
        XCTAssertEqual(live.busy, 2)
        XCTAssertEqual(live.idle, 3)
        XCTAssertEqual(live.waiting, 1)
        XCTAssertEqual(live.shell, 1)
        XCTAssertEqual(live.unknown, 2)
    }

    func testOldEngineWithoutBreakdownStillDecodes() throws {
        let live = try JSONDecoder().decode(
            LiveSessions.self, from: Data(#"{"busy":1,"total":4}"#.utf8))
        XCTAssertEqual(live.busy, 1)
        XCTAssertNil(live.idle)
    }
}

final class SessionSummaryTests: XCTestCase {
    func testBreakdownTooltipSkipsZeroBuckets() throws {
        let live = try JSONDecoder().decode(LiveSessions.self, from: Data(
            #"{"busy":4,"idle":7,"waiting":0,"shell":1,"unknown":2,"total":14}"#.utf8))
        XCTAssertEqual(
            SessionSummary.tooltip(live),
            "4 working · 7 idle · 1 in shell · 2 unknown of "
            + "14 live Claude Code sessions — all ride the active account")
    }

    func testOldEngineFallsBackToTwoNumbers() throws {
        let live = try JSONDecoder().decode(
            LiveSessions.self, from: Data(#"{"busy":1,"total":3}"#.utf8))
        XCTAssertTrue(SessionSummary.tooltip(live).hasPrefix("1 session(s) mid-turn"))
    }
}

final class TitleFormatterIconTests: XCTestCase {
    private func account(pct: Double) -> Account {
        try! JSONDecoder().decode(Account.self, from: Data("""
        {"number": 1, "email": "a@x.com", "organizationName": "",
         "organizationUuid": "", "isOrganization": false, "active": true,
         "usageStatus": "ok",
         "usage": {"fiveHour": {"pct": \(pct)}}}
        """.utf8))
    }

    func testEmptyIconDropsTheGlyphAndItsSpace() {
        let prefs = TitlePrefs(showAccountName: true, titlePct: "5h", titleScoped: false)
        let text = TitleFormatter.format(account: account(pct: 42), prefs: prefs, icon: "")
        XCTAssertEqual(text, "a · 42%")
        XCTAssertEqual(TitleFormatter.format(account: nil, prefs: prefs, icon: ""), "")
    }

    func testDefaultKeepsTheTextGlyph() {
        let prefs = TitlePrefs(showAccountName: false, titlePct: "5h", titleScoped: false)
        XCTAssertEqual(TitleFormatter.format(account: account(pct: 42), prefs: prefs),
                       "⇄ 42%")
    }
}

final class ReadyLabelThemeTests: XCTestCase {
    func testMinimalCustomThemeDefaultsToReady() throws {
        let themes = try JSONDecoder().decode(
            [RowTheme].self, from: Data(#"[{"id":"x","name":"X"}]"#.utf8))
        XCTAssertEqual(themes.first?.readyLabel, "ready")
    }

    func testBuiltinsCarryThemedReadyWords() {
        XCTAssertEqual(RowTheme.rpg.readyLabel, "full HP")
        XCTAssertEqual(RowTheme.off.readyLabel, "ready")
    }
}

final class SettingsSyncSnapshotTests: XCTestCase {
    func testSnapshotRoundTrips() throws {
        var snap = SyncSnapshot()
        snap.app = ["compact_rows": .bool(true), "refresh_interval": .number(60),
                    "popup_layout": .string("wide")]
        snap.themes = [RowTheme(id: "x", name: "X", readyLabel: "GO")]
        snap.engine = ["autoswitch.threshold": "98.0"]
        XCTAssertEqual(SyncSnapshot.decode(try snap.encoded()), snap)
    }
}

final class PushTriggersTests: XCTestCase {
    private func acct(_ n: Int, dead: Bool, pct: Double? = nil) -> PushTriggers.Account {
        PushTriggers.Account(number: n, name: "a\(n)", dead: dead, worstPct: pct)
    }
    private let all = PushTriggers.Flags()

    func testSessionsDoneNeedsTwoQuietTicks() {
        var t = PushTriggers()
        XCTAssertEqual(t.tick(busy: 3, total: 5, accounts: [], flags: all), [])
        XCTAssertEqual(t.tick(busy: 0, total: 5, accounts: [], flags: all), [])
        XCTAssertEqual(t.tick(busy: 0, total: 5, accounts: [], flags: all),
                       ["all sessions finished — 0 of 5 working"])
        // Quiet stays quiet: no repeat until a new busy episode.
        XCTAssertEqual(t.tick(busy: 0, total: 5, accounts: [], flags: all), [])
        XCTAssertEqual(t.tick(busy: 2, total: 5, accounts: [], flags: all), [])
        XCTAssertEqual(t.tick(busy: 0, total: 5, accounts: [], flags: all), [])
        XCTAssertEqual(t.tick(busy: 0, total: 5, accounts: [], flags: all).count, 1)
    }

    func testSingleTickDipBetweenTurnsStaysSilent() {
        var t = PushTriggers()
        for (busy, expect) in [(3, 0), (0, 0), (2, 0), (0, 0), (0, 1)] {
            XCTAssertEqual(t.tick(busy: busy, total: 5, accounts: [], flags: all).count,
                           expect, "busy=\(busy)")
        }
    }

    func testAllDeadFiresOnceAndRearmsAfterRecovery() {
        var t = PushTriggers()
        let dead = [acct(1, dead: true), acct(2, dead: true)]
        XCTAssertEqual(t.tick(busy: nil, total: nil, accounts: dead, flags: all),
                       ["all 2 accounts exhausted — nothing left to switch to"])
        XCTAssertEqual(t.tick(busy: nil, total: nil, accounts: dead, flags: all), [])
        _ = t.tick(busy: nil, total: nil,
                   accounts: [acct(1, dead: false, pct: 10), acct(2, dead: true)],
                   flags: all)
        XCTAssertEqual(t.tick(busy: nil, total: nil, accounts: dead, flags: all).count, 1)
    }

    func testNoAccountsIsNeverAllDead() {
        var t = PushTriggers()
        XCTAssertEqual(t.tick(busy: nil, total: nil, accounts: [], flags: all), [])
    }

    func testLastAliveWarnsOnceWithHysteresis() {
        var t = PushTriggers()
        let warn = [acct(1, dead: true), acct(2, dead: false, pct: 92)]
        XCTAssertEqual(t.tick(busy: nil, total: nil, accounts: warn, flags: all),
                       ["last account standing — a2 at 92%"])
        XCTAssertEqual(t.tick(busy: nil, total: nil, accounts: warn, flags: all), [])
        // 87% sits inside the hysteresis band: no re-arm, no repeat.
        _ = t.tick(busy: nil, total: nil,
                   accounts: [acct(1, dead: true), acct(2, dead: false, pct: 87)],
                   flags: all)
        XCTAssertEqual(t.tick(busy: nil, total: nil, accounts: warn, flags: all), [])
        // Dropping under 85% re-arms.
        _ = t.tick(busy: nil, total: nil,
                   accounts: [acct(1, dead: true), acct(2, dead: false, pct: 40)],
                   flags: all)
        XCTAssertEqual(t.tick(busy: nil, total: nil, accounts: warn, flags: all).count, 1)
    }

    func testTwoAliveAccountsNeverWarn() {
        var t = PushTriggers()
        let accounts = [acct(1, dead: false, pct: 95), acct(2, dead: false, pct: 99)]
        XCTAssertEqual(t.tick(busy: nil, total: nil, accounts: accounts, flags: all), [])
    }

    func testDisabledFlagSuppressesTheMessageButAdvancesState() {
        var t = PushTriggers()
        let off = PushTriggers.Flags(sessionsDone: false, allDead: true, lastAlive: true)
        _ = t.tick(busy: 3, total: 5, accounts: [], flags: off)
        _ = t.tick(busy: 0, total: 5, accounts: [], flags: off)
        XCTAssertEqual(t.tick(busy: 0, total: 5, accounts: [], flags: off), [])
        // Turning the flag on afterwards must not fire the stale episode.
        XCTAssertEqual(t.tick(busy: 0, total: 5, accounts: [], flags: all), [])
    }

    func testWorstPlanPctExcludesSpend() throws {
        let usage = try JSONDecoder().decode(Usage.self, from: Data("""
        {"fiveHour": {"pct": 10}, "sevenDay": {"pct": 55},
         "scoped": [{"name": "Fable", "pct": 70}],
         "spend": {"pct": 100, "used": 5, "limit": 5, "currency": "USD"}}
        """.utf8))
        XCTAssertEqual(PushTriggers.worstPlanPct(usage), 70)
    }
}
