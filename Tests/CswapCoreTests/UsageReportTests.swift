import XCTest
@testable import CswapCore

final class UsageReportTests: XCTestCase {
    func testDecodesReport() throws {
        let json = """
        {"schemaVersion":1,"days":7,"estimatedTotalUSD":75.5,
         "priceTable":{"source":"models.dev","date":"2026-08-28"},
         "accounts":[{"number":1,"email":"a@x.io","alias":"dev",
           "estimatedUSD":75.5,"messages":10,"input":5,"output":6,
           "cacheRead":7,"cacheWrite":8,
           "models":[{"model":"claude-opus-5","estimatedUSD":75.5,"messages":10}]}],
         "caveats":["NOT billing truth."]}
        """
        let r = try JSONDecoder().decode(UsageReport.self, from: Data(json.utf8))
        XCTAssertEqual(r.estimatedTotalUSD, 75.5)
        XCTAssertEqual(r.accounts.first?.alias, "dev")
        XCTAssertNil(r.unattributed)   // optional buckets absent when empty
        XCTAssertNil(r.unpricedTokens)
        XCTAssertEqual(r.accounts.first?.models.first?.model, "claude-opus-5")
    }

    func testCompactTokenFormat() {
        XCTAssertEqual(TokenFormat.compact(950), "950")
        XCTAssertEqual(TokenFormat.compact(12_300), "12.3k")
        XCTAssertEqual(TokenFormat.compact(4_500_000), "4.5M")
        XCTAssertEqual(TokenFormat.compact(1_200_000_000), "1.2B")
    }
}
