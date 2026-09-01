import XCTest
@testable import CswapCore

/// Decoding is tested against fixtures captured from the real CLI
/// (sanitized: emails and org UUIDs replaced), so the Swift models can only
/// drift from `cswap --json` by failing here first.
final class ModelsTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)!
        return try Data(contentsOf: url)
    }

    func testAccountListDecodesTheRealPayload() throws {
        let list = try JSONDecoder().decode(AccountList.self, from: fixture("list.json"))
        XCTAssertEqual(list.schemaVersion, 1)
        XCTAssertEqual(list.accounts.count, 5)
        XCTAssertEqual(list.activeAccountNumber, 5)
        let first = list.accounts[0]
        XCTAssertEqual(first.number, 1)
        XCTAssertEqual(first.usageStatus, "ok")
        XCTAssertEqual(first.usage?.sevenDay?.pct, 100.0)
        XCTAssertEqual(first.usage?.scoped?.first?.name, "Fable")
        XCTAssertNotNil(first.usage?.sevenDay?.countdown)
        XCTAssertEqual(list.liveSessions?.busy, 4)
        XCTAssertEqual(list.liveSessions?.idle, 7)
        XCTAssertEqual(list.liveSessions?.unknown, 2)
    }

    func testNextRecoveryDecodesAndIsOptional() throws {
        let json = """
        {"schemaVersion": 1, "activeAccountNumber": 3, "accounts": [],
         "nextRecovery": {"number": 2, "at": "2026-08-30T09:00:00+00:00"}}
        """
        let list = try JSONDecoder().decode(AccountList.self, from: Data(json.utf8))
        XCTAssertNil(list.nextCandidate)
        XCTAssertEqual(list.nextRecovery?.number, 2)
        XCTAssertEqual(list.nextRecovery?.at, "2026-08-30T09:00:00+00:00")
        // Older engines omit the key entirely.
        let bare = """
        {"schemaVersion": 1, "activeAccountNumber": null, "accounts": []}
        """
        XCTAssertNil(try JSONDecoder()
            .decode(AccountList.self, from: Data(bare.utf8)).nextRecovery)
    }

    func testSentinelAccountHasNilUsageNotADecodeError() throws {
        let json = """
        {"schemaVersion": 1, "activeAccountNumber": null, "accounts": [
          {"number": 2, "email": "x@example.com", "organizationName": "",
           "organizationUuid": "", "isOrganization": false, "active": false,
           "usageStatus": "no_credentials", "usage": null}]}
        """
        let list = try JSONDecoder().decode(AccountList.self, from: Data(json.utf8))
        XCTAssertNil(list.accounts[0].usage)
        XCTAssertNil(list.activeAccountNumber)
        XCTAssertEqual(list.accounts[0].usageStatus, "no_credentials")
    }

    func testConfigListCarriesSpecMetadata() throws {
        let cfg = try JSONDecoder().decode(ConfigList.self, from: fixture("config.json"))
        let threshold = cfg.settings.first { $0.key == "autoswitch.threshold" }!
        XCTAssertEqual(threshold.kind, "float")
        XCTAssertEqual(threshold.lo, 50.0)
        XCTAssertEqual(threshold.hi, 99.9)
        XCTAssertFalse(threshold.help.isEmpty)
        let strategy = cfg.settings.first { $0.key == "autoswitch.strategy" }!
        XCTAssertTrue(strategy.choices?.contains("consume-first") ?? false)
        if case .string(let d) = strategy.defaultValue { XCTAssertEqual(d, "best") }
        else { XCTFail("default should be a string") }
    }

    func testHeterogeneousSettingValuesDecode() throws {
        let cfg = try JSONDecoder().decode(ConfigList.self, from: fixture("config.json"))
        let kinds = Set(cfg.settings.map(\.kind))
        XCTAssertTrue(kinds.contains("bool"))
        XCTAssertTrue(kinds.contains("float"))
        // Every value decoded into some JSONValue without throwing — the
        // point of the enum. Spot-check a bool round-trips as a bool.
        let resume = cfg.settings.first { $0.key == "autoswitch.resumeStoppedSessions" }!
        if case .bool = resume.value {} else { XCTFail("bool value expected") }
    }
}

final class ChillDepthTests: XCTestCase {
    func testBehindPaceScales() {
        XCTAssertEqual(GaugeMath.chillDepth(usedPct: 22, expectedPct: 31, ahead: false),
                       0.3, accuracy: 0.001)
        XCTAssertEqual(GaugeMath.chillDepth(usedPct: 0, expectedPct: 40, ahead: false), 1)
    }

    func testZeroUnlessExplicitlyNotAhead() {
        // nil ahead means the engine sent no pace verdict — no effect,
        // symmetric with burnHeat's `ahead == true` guard.
        XCTAssertEqual(GaugeMath.chillDepth(usedPct: 10, expectedPct: 40, ahead: nil), 0)
        XCTAssertEqual(GaugeMath.chillDepth(usedPct: 10, expectedPct: 40, ahead: true), 0)
        XCTAssertEqual(GaugeMath.chillDepth(usedPct: 10, expectedPct: nil, ahead: false), 0)
        XCTAssertEqual(GaugeMath.chillDepth(usedPct: 50, expectedPct: 40, ahead: false), 0)
    }
}
