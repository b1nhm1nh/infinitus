import XCTest
import CswapCore

private func account(_ json: String) throws -> Account {
    try JSONDecoder().decode(Account.self, from: Data(json.utf8))
}

private let base = #""email": "dev@example.com", "organizationName": "o", "organizationUuid": "u", "isOrganization": true"#

final class RecoveryMathTests: XCTestCase {
    // (a) the reported bug: the active account is both dead and the
    // soonest reviver, but the engine's advisory (mirrored by
    // `_next_recovery`'s active-skip) would have named a later account.
    // RecoveryMath.nextRecovery must not exclude the active account.
    func testActiveAccountWinsWhenSoonest() throws {
        let active = try account(#"{"number": 1, \#(base), "active": true, "usageStatus": "ok", "usage": {"fiveHour": {"pct": 100, "resetsAt": "2026-09-02T00:27:00Z"}, "sevenDay": {"pct": 40, "resetsAt": "2026-09-05T00:00:00Z"}}}"#)
        let other = try account(#"{"number": 2, \#(base), "active": false, "usageStatus": "ok", "usage": {"fiveHour": {"pct": 100, "resetsAt": "2026-09-02T01:07:23Z"}, "sevenDay": {"pct": 40, "resetsAt": "2026-09-05T00:00:00Z"}}}"#)
        let result = RecoveryMath.nextRecovery(accounts: [active, other])
        XCTAssertEqual(result?.number, 1)
        XCTAssertEqual(result?.at, "2026-09-02T00:27:00Z")
    }

    // (b) disabled accounts are skipped even if they'd otherwise win.
    func testDisabledAccountsSkipped() throws {
        let disabled = try account(#"{"number": 3, \#(base), "active": false, "disabled": true, "usageStatus": "ok", "usage": {"fiveHour": {"pct": 100, "resetsAt": "2026-01-01T00:00:00Z"}}}"#)
        let alive = try account(#"{"number": 4, \#(base), "active": false, "usageStatus": "ok", "usage": {"fiveHour": {"pct": 100, "resetsAt": "2026-09-05T00:00:00Z"}}}"#)
        let result = RecoveryMath.nextRecovery(accounts: [disabled, alive])
        XCTAssertEqual(result?.number, 4)
    }

    // (c) a maxed window with no resetsAt makes the account unrankable —
    // it's skipped, not treated as "resets immediately".
    func testUnrankableMaxedWindowSkipsAccount() throws {
        let unrankable = try account(#"{"number": 5, \#(base), "active": false, "usageStatus": "ok", "usage": {"fiveHour": {"pct": 100}}}"#)
        let rankable = try account(#"{"number": 6, \#(base), "active": false, "usageStatus": "ok", "usage": {"fiveHour": {"pct": 100, "resetsAt": "2026-09-05T00:00:00Z"}}}"#)
        let result = RecoveryMath.nextRecovery(accounts: [unrankable, rankable])
        XCTAssertEqual(result?.number, 6)
    }

    // (d) corrected() must not invent an all-dead premise: nil engine
    // value stays nil even if every account looks dead client-side.
    func testCorrectedNilWhenEngineNil() throws {
        let dead = try account(#"{"number": 7, \#(base), "active": true, "usageStatus": "ok", "usage": {"fiveHour": {"pct": 100, "resetsAt": "2026-09-05T00:00:00Z"}}}"#)
        XCTAssertNil(RecoveryMath.corrected(engine: nil, accounts: [dead]))
    }

    // (e) falls back to the engine's value when the client can't rank
    // anyone (e.g. all maxed windows are unrankable).
    func testCorrectedFallsBackWhenUnrankable() throws {
        let unrankable = try account(#"{"number": 8, \#(base), "active": true, "usageStatus": "ok", "usage": {"fiveHour": {"pct": 100}}}"#)
        let engineValue = NextRecovery(number: 8, at: "2026-09-05T00:00:00Z")
        let result = RecoveryMath.corrected(engine: engineValue, accounts: [unrankable])
        XCTAssertEqual(result?.number, 8)
        XCTAssertEqual(result?.at, "2026-09-05T00:00:00Z")
    }
}
