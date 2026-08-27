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
