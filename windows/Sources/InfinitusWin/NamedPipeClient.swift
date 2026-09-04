import Foundation
import WinSDK

/// The client half of a session's messaging pipe
/// (`\\.\pipe\LOCAL\cc-msg-<hex>`, the record's `messagingSocketPath`).
/// W10 adds `write` (CreateFileW + WriteFile of PeerSocket.frames bytes);
/// today only the non-intrusive liveness probe lives here.
enum NamedPipe {
    /// `WaitNamedPipeW(path, 0)`: a server instance exists. Never
    /// connects, never writes a byte — probing is free of side effects on
    /// the session. ERROR_PIPE_BUSY still means the server is there; its
    /// instances are merely busy.
    static func isListening(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let wide = Array(path.utf16) + [0]
        if WaitNamedPipeW(wide, 0) { return true }
        return GetLastError() == DWORD(ERROR_PIPE_BUSY)
    }
}
