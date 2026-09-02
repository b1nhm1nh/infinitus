import XCTest
@testable import CswapCore

/// A read-only engine: declares nothing beyond snapshots.
private struct StubEngine: AccountEngine {
    let id = "stub"
    let displayName = "Stub"
    let capabilities: EngineCapabilities = []
    let fleets: [EngineFleet]
    func snapshot() async throws -> [EngineFleet] { fleets }
}

final class AccountEngineTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)!
        return try Data(contentsOf: url)
    }

    func testDefaultActionsThrowUnsupported() async {
        let engine = StubEngine(fleets: [])
        do {
            try await engine.switchTo(fleet: .claude, number: 1)
            XCTFail("switch should be unsupported")
        } catch let e as EngineError {
            XCTAssertEqual(e, .unsupported("switch"))
        } catch { XCTFail("wrong error \(error)") }
        do {
            _ = try await engine.usageReport(days: 7)
            XCTFail("cost should be unsupported")
        } catch let e as EngineError {
            XCTAssertEqual(e, .unsupported("costReport"))
        } catch { XCTFail("wrong error \(error)") }
    }

    func testFleetRoundTripsThroughJSONWithRawBytes() throws {
        let raw = try fixture("list.json")
        let list = try JSONDecoder().decode(AccountList.self, from: raw)
        let fleet = CswapEngine.fleet(from: list, raw: raw)
        XCTAssertEqual(fleet.key, "cswap/claude")
        XCTAssertEqual(fleet.activeNumber, 5)
        let data = try JSONEncoder().encode([fleet])
        let back = try JSONDecoder().decode([EngineFleet].self, from: data)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].accounts.count, list.accounts.count)
        XCTAssertEqual(back[0].raw, raw)
        XCTAssertEqual(back[0].liveSessions?.busy, 4)
        // The raw bytes still decode as the cswap payload the phone reads.
        let again = try JSONDecoder().decode(AccountList.self, from: back[0].raw!)
        XCTAssertEqual(again.activeAccountNumber, 5)
    }

    func testCswapDeclaresEverything() {
        let engine = CswapEngine(cli: CswapCLI(binaryPath: "/nonexistent"))
        XCTAssertEqual(engine.capabilities, .all)
        XCTAssertTrue(engine.capabilities.contains(.hold))
        XCTAssertFalse(StubEngine(fleets: []).capabilities.contains(.switch))
    }

    func testProviderOrderingIsClaudeFirst() {
        XCTAssertEqual(Provider.allCases.first, .claude)
        XCTAssertEqual(Provider.codex.displayName, "Codex")
    }
}
