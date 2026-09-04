import XCTest
#if os(Windows)
import WinSDK
#endif
@testable import InfinitusCore

/// W2 placeholder: proves the daemon's core dependency works on Windows
/// (liveness of the running test host's own process) until W3/W4/W5 add the
/// real suites. Deliberately does NOT `@testable import InfinitusWin` —
/// importing the executable's module kills the test host.
final class VersionTests: XCTestCase {
    func testCoreIsLinkedAndCanQueryAProcess() {
        XCTAssertTrue(ClaudeSessions.isAlive(Int32(GetCurrentProcessId())))
    }
}
