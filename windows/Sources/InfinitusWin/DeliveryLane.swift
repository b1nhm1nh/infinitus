import Foundation
import InfinitusCore

/// One delivery path for HTTP input, the control pipe, and the team grantor.
///
/// `Routes.input`, `ControlServer.message` and `TeamSupervisor` all used to
/// call `SessionInput.deliver` themselves. A grantor execute and a
/// `POST /sessions/<pid>/input` can share a connection-thread listener
/// (`WinHTTPServer` is one thread per connection), so two callers can race
/// frames into the same named pipe. The Mac hops `storePass` onto
/// `MirrorTeamControlBox.queue` for this; here the queue lives next to the
/// call so every lane takes it.
enum DeliveryLane {
    static let queue = DispatchQueue(label: "run.infinitus.win.input")

    /// Owned stdin first (`owned.existing?.deliver`), then `NamedPipe.send`.
    /// `hosts: []` — Windows Terminal has no send-keys, so a `key` on a
    /// session nobody owns answers `noSurface` rather than pretending.
    static func deliver(
        pid: Int32,
        request: SessionInput.Request,
        owned: OwnedSessionsBox,
        claudeDir: URL,
        deliverOverride: (@Sendable (SessionInput.Request, ClaudeSessionRecord) -> SessionInput.Reply?)? = nil
    ) -> SessionInput.Reply {
        queue.sync {
            guard let record = ClaudeSessions.list(claudeDir: claudeDir).first(where: { $0.pid == pid }) else {
                return SessionInput.Reply(outcome: "noChannel",
                                          detail: "no live session with pid \(pid)")
            }
            let deliver = deliverOverride ?? owned.existing?.deliver
            return SessionInput.deliver(
                request: request, record: record,
                hosts: [],
                claudeDir: claudeDir,
                ttyOfPid: { _ in nil }, ancestorsOf: { _ in [] },
                socketSend: { record, text in
                    NamedPipe.send(text: text, record: record, claudeDir: claudeDir)
                },
                owned: deliver)
        }
    }
}
