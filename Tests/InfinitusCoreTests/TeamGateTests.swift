import XCTest
@testable import InfinitusCore

final class TeamGateTests: XCTestCase {
    func testLockOnAllows() {
        XCTAssertEqual(TeamGate.check(lockEnabled: true, environment: [:]), .allowed)
    }

    func testLockOffNeedsTheLockWithTheSpecCopy() {
        XCTAssertEqual(TeamGate.check(lockEnabled: false, environment: [:]),
                       .needsLock("Turn on biometric unlock first"))
        XCTAssertEqual(TeamGate.reason, "Turn on biometric unlock first")
    }

    func testPlatformWithoutALockIsOpen() {
        XCTAssertEqual(TeamGate.check(lockEnabled: nil, environment: [:]), .allowed)
    }

    func testHatchOpensTheGateOnlyWhenItSaysOpen() {
        XCTAssertEqual(TeamGate.check(lockEnabled: false, environment: ["INFINITUS_LOCK_GATE": "open"]), .allowed)
        XCTAssertEqual(TeamGate.check(lockEnabled: false, environment: ["INFINITUS_LOCK_GATE": "1"]),
                       .needsLock(TeamGate.reason))
        XCTAssertEqual(TeamGate.bypassVariable, "INFINITUS_LOCK_GATE")
    }

    func testMachineReadHasAnAnswerOnlyWhereALockExists() {
        #if os(macOS)
        XCTAssertNotNil(LockSetting.enabledOnThisMachine())
        #else
        XCTAssertNil(LockSetting.enabledOnThisMachine())
        #endif
    }
}
