import Foundation
import InfinitusCore
#if os(Windows)
import WinSDK
import CRT
#endif

/// Lazily-made `OwnedSessions` (#151), shared by the start handlers
/// and the input route. `existing` never creates one: a request into a
/// session nobody owns must not pay for locating `claude`.
final class OwnedSessionsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var instance: OwnedSessions?
    private var tried = false

    var existing: OwnedSessions? {
        lock.lock(); defer { lock.unlock() }
        return instance
    }

    func get(make: () -> OwnedSessions?) -> OwnedSessions? {
        lock.lock(); defer { lock.unlock() }
        if !tried {
            tried = true
            instance = make()
        }
        return instance
    }

    /// Ctrl-C / atexit: owned children are this process's, so they must
    /// not outlive the daemon (the #274 lesson, same as the Mac quit path).
    func installShutdown() {
        Self.shutdownLock.lock()
        Self.shutdownBox = self
        if Self.hooked {
            Self.shutdownLock.unlock()
            return
        }
        Self.hooked = true
        Self.shutdownLock.unlock()
        #if os(Windows)
        atexit {
            OwnedSessionsBox.stopOwned()
        }
        SetConsoleCtrlHandler({ _ in
            OwnedSessionsBox.stopOwned()
            return false
        }, true)
        #endif
    }

    private static let shutdownLock = NSLock()
    private static var shutdownBox: OwnedSessionsBox?
    private static var hooked = false

    static func stopOwned() {
        shutdownLock.lock()
        let box = shutdownBox
        shutdownBox = nil
        shutdownLock.unlock()
        guard let owned = box?.existing else { return }
        let done = DispatchSemaphore(value: 0)
        Task { await owned.stopAll(); done.signal() }
        // The console gives the handler a few seconds; don't outrun it.
        _ = done.wait(timeout: .now() + 5)
    }
}
