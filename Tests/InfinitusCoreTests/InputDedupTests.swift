import XCTest
@testable import InfinitusCore

final class InputDedupTests: XCTestCase {
    func testSecondSightIsFalse() {
        var dedup = InputDedup()
        XCTAssertTrue(dedup.firstSight(pid: 7, requestId: "a"))
        XCTAssertFalse(dedup.firstSight(pid: 7, requestId: "a"))
    }

    func testPidsAreIsolated() {
        var dedup = InputDedup()
        XCTAssertTrue(dedup.firstSight(pid: 7, requestId: "a"))
        XCTAssertTrue(dedup.firstSight(pid: 8, requestId: "a"))
    }

    func testRingEvictsTheOldest() {
        var dedup = InputDedup(capacity: 3)
        for id in ["a", "b", "c"] { XCTAssertTrue(dedup.firstSight(pid: 1, requestId: id)) }
        XCTAssertTrue(dedup.firstSight(pid: 1, requestId: "d"))   // evicts "a"
        XCTAssertTrue(dedup.firstSight(pid: 1, requestId: "a"))   // forgotten
        XCTAssertFalse(dedup.firstSight(pid: 1, requestId: "d"))
    }
}
