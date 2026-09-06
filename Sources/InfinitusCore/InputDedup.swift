import Foundation

/// #168: the phone's outbox may deliver a request twice (it died between
/// the send and the reply, or the reply was lost); the Mac answers the
/// repeat without touching the session. A short ring per pid is enough —
/// a phone never has more than one queued request per session, and a
/// hand-retried send reuses its id for a few seconds, not days.
public struct InputDedup: Sendable {
    private let capacity: Int
    private var seen: [Int32: [String]] = [:]

    public init(capacity: Int = 64) {
        self.capacity = max(1, capacity)
    }

    /// True the first time `(pid, requestId)` is seen; false on a repeat.
    public mutating func firstSight(pid: Int32, requestId: String) -> Bool {
        var ring = seen[pid] ?? []
        if ring.contains(requestId) { return false }
        ring.append(requestId)
        if ring.count > capacity { ring.removeFirst(ring.count - capacity) }
        seen[pid] = ring
        return true
    }
}
